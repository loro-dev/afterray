//! Identity of a Unix-socket peer.
//!
//! Privilege is **not** the on-disk path. Anyone on the same uid can copy a
//! binary to `/tmp/afterray-app`. The daemon reads the peer audit token from
//! the socket and asks Security.framework whether that process is a valid
//! `dev.afterray.app` signature. Production also requires the peer's Team ID
//! to match this daemon's Team ID. Ad-hoc / unsigned daemons (the `make v0`
//! fallback) only trust that identifier when
//! `AFTERRAY_DEV_TRUST_IDENTIFIER=1` is set by the app that spawned them.

/// Bundle identifier stamped on AfterRay.app (and the ad-hoc designated
/// requirement used by `run-v0.sh`).
pub const APP_BUNDLE_IDENTIFIER: &str = "dev.afterray.app";

/// Honour identifier-only trust when this daemon has no Team ID.
/// The packaged Developer ID daemon ignores this even if it is set.
pub const DEV_TRUST_IDENTIFIER_ENV: &str = "AFTERRAY_DEV_TRUST_IDENTIFIER";

/// `fd` is the accepted connection, not the listening socket.
#[must_use]
pub fn peer_is_afterray_app(fd: i32) -> bool {
    #[cfg(target_os = "macos")]
    {
        macos::peer_is_afterray_app(fd)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = fd;
        false
    }
}

/// Pure policy so the path-spoof case is a unit test, not a codesign fixture.
#[must_use]
pub fn app_peer_is_trusted(
    identifier: &str,
    peer_team: Option<&str>,
    signature_valid: bool,
    self_team: Option<&str>,
    dev_identifier_trust: bool,
) -> bool {
    if !signature_valid || identifier != APP_BUNDLE_IDENTIFIER {
        return false;
    }
    match self_team {
        Some(team) => peer_team == Some(team),
        None => dev_identifier_trust,
    }
}

#[must_use]
pub fn dev_identifier_trust_enabled() -> bool {
    matches!(std::env::var(DEV_TRUST_IDENTIFIER_ENV).as_deref(), Ok("1"))
}

#[cfg(target_os = "macos")]
mod macos {
    use super::{app_peer_is_trusted, dev_identifier_trust_enabled, APP_BUNDLE_IDENTIFIER};
    use core_foundation::base::{CFRelease, CFType, CFTypeRef, TCFType};
    use core_foundation::data::CFData;
    use core_foundation::dictionary::CFDictionary;
    use core_foundation::string::{CFString, CFStringRef};
    use std::ffi::c_void;
    use std::ptr;

    /// `sys/un.h` — not always exposed by the `libc` crate.
    const LOCAL_PEERTOKEN: libc::c_int = 0x006;
    const ERR_SEC_SUCCESS: i32 = 0;
    const SEC_CS_DEFAULT_FLAGS: u32 = 0;
    const SEC_CS_SIGNING_INFORMATION: u32 = 1 << 1;

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct AuditToken {
        val: [u32; 8],
    }

    type SecCodeRef = *const c_void;
    type SecRequirementRef = *const c_void;

    #[link(name = "Security", kind = "framework")]
    unsafe extern "C" {
        static kSecGuestAttributeAudit: CFStringRef;
        static kSecCodeInfoIdentifier: CFStringRef;
        static kSecCodeInfoTeamIdentifier: CFStringRef;

        fn SecCodeCopyGuestWithAttributes(
            host: SecCodeRef,
            attributes: CFTypeRef,
            flags: u32,
            out: *mut SecCodeRef,
        ) -> i32;
        fn SecCodeCopySelf(flags: u32, out: *mut SecCodeRef) -> i32;
        fn SecCodeCopySigningInformation(code: SecCodeRef, flags: u32, out: *mut CFTypeRef) -> i32;
        fn SecCodeCheckValidity(
            code: SecCodeRef,
            flags: u32,
            requirement: SecRequirementRef,
        ) -> i32;
        fn SecRequirementCreateWithString(
            text: CFStringRef,
            flags: u32,
            out: *mut SecRequirementRef,
        ) -> i32;
    }

    struct OwnedCf(*const c_void);

    impl Drop for OwnedCf {
        fn drop(&mut self) {
            if !self.0.is_null() {
                unsafe { CFRelease(self.0) };
            }
        }
    }

    pub fn peer_is_afterray_app(fd: i32) -> bool {
        let Some(token) = peer_audit_token(fd) else {
            return false;
        };
        let Some(guest) = code_for_audit_token(&token) else {
            return false;
        };
        let Some(info) = signing_info(guest.0) else {
            return false;
        };
        let self_team = self_team_id();
        if !app_peer_is_trusted(
            &info.identifier,
            info.team_id.as_deref(),
            info.valid,
            self_team.as_deref(),
            dev_identifier_trust_enabled(),
        ) {
            return false;
        }
        requirement_holds(guest.0, &designated_requirement(self_team.as_deref()))
    }

    fn designated_requirement(self_team: Option<&str>) -> String {
        match self_team {
            Some(team) => format!(
                r#"identifier "{APP_BUNDLE_IDENTIFIER}" and certificate leaf[subject.OU] = "{team}""#
            ),
            None => format!(r#"identifier "{APP_BUNDLE_IDENTIFIER}""#),
        }
    }

    fn peer_audit_token(fd: i32) -> Option<AuditToken> {
        let mut token = AuditToken { val: [0; 8] };
        let mut len = libc::socklen_t::try_from(std::mem::size_of::<AuditToken>()).ok()?;
        let rc = unsafe {
            libc::getsockopt(
                fd,
                libc::SOL_LOCAL,
                LOCAL_PEERTOKEN,
                std::ptr::from_mut(&mut token).cast(),
                &raw mut len,
            )
        };
        if rc != 0 {
            return None;
        }
        if usize::try_from(len).ok()? != std::mem::size_of::<AuditToken>() {
            return None;
        }
        Some(token)
    }

    fn code_for_audit_token(token: &AuditToken) -> Option<OwnedCf> {
        let bytes = unsafe {
            std::slice::from_raw_parts(
                std::ptr::from_ref(token).cast::<u8>(),
                std::mem::size_of::<AuditToken>(),
            )
        };
        let data = CFData::from_buffer(bytes);
        let key = unsafe { CFString::wrap_under_get_rule(kSecGuestAttributeAudit) };
        let attributes: CFDictionary<CFString, CFType> =
            CFDictionary::from_CFType_pairs(&[(key, data.as_CFType())]);
        let mut guest: SecCodeRef = ptr::null();
        let status = unsafe {
            SecCodeCopyGuestWithAttributes(
                ptr::null(),
                attributes.as_concrete_TypeRef().cast(),
                SEC_CS_DEFAULT_FLAGS,
                &raw mut guest,
            )
        };
        if status != ERR_SEC_SUCCESS || guest.is_null() {
            return None;
        }
        Some(OwnedCf(guest))
    }

    struct SigningInfo {
        identifier: String,
        team_id: Option<String>,
        valid: bool,
    }

    fn signing_info(code: SecCodeRef) -> Option<SigningInfo> {
        let valid = unsafe { SecCodeCheckValidity(code, SEC_CS_DEFAULT_FLAGS, ptr::null()) }
            == ERR_SEC_SUCCESS;
        let mut info: CFTypeRef = ptr::null();
        let status = unsafe {
            SecCodeCopySigningInformation(code, SEC_CS_SIGNING_INFORMATION, &raw mut info)
        };
        if status != ERR_SEC_SUCCESS || info.is_null() {
            return None;
        }
        let _release = OwnedCf(info);
        let dict = unsafe { CFDictionary::<CFString, CFType>::wrap_under_get_rule(info.cast()) };
        let identifier_key = unsafe { CFString::wrap_under_get_rule(kSecCodeInfoIdentifier) };
        let team_key = unsafe { CFString::wrap_under_get_rule(kSecCodeInfoTeamIdentifier) };
        let identifier = dict
            .find(&identifier_key)
            .and_then(|value| value.downcast::<CFString>())
            .map(|value| value.to_string())?;
        let team_id = dict
            .find(&team_key)
            .and_then(|value| value.downcast::<CFString>())
            .map(|value| value.to_string())
            .filter(|value| !value.is_empty());
        Some(SigningInfo {
            identifier,
            team_id,
            valid,
        })
    }

    fn self_team_id() -> Option<String> {
        let mut code: SecCodeRef = ptr::null();
        let status = unsafe { SecCodeCopySelf(SEC_CS_DEFAULT_FLAGS, &raw mut code) };
        if status != ERR_SEC_SUCCESS || code.is_null() {
            return None;
        }
        let _release = OwnedCf(code);
        signing_info(code)?.team_id
    }

    fn requirement_holds(code: SecCodeRef, text: &str) -> bool {
        let cf_text = CFString::new(text);
        let mut requirement: SecRequirementRef = ptr::null();
        let status = unsafe {
            SecRequirementCreateWithString(
                cf_text.as_concrete_TypeRef(),
                SEC_CS_DEFAULT_FLAGS,
                &raw mut requirement,
            )
        };
        if status != ERR_SEC_SUCCESS || requirement.is_null() {
            return false;
        }
        let _release = OwnedCf(requirement);
        let status = unsafe { SecCodeCheckValidity(code, SEC_CS_DEFAULT_FLAGS, requirement) };
        status == ERR_SEC_SUCCESS
    }
}

#[cfg(test)]
mod tests {
    use super::{app_peer_is_trusted, APP_BUNDLE_IDENTIFIER};

    #[test]
    fn a_renamed_binary_is_not_the_app() {
        assert!(!app_peer_is_trusted("afterray-app", None, true, None, true,));
        assert!(!app_peer_is_trusted(
            "afterray",
            Some("TEAMID"),
            true,
            Some("TEAMID"),
            false
        ));
    }

    #[test]
    fn production_requires_matching_team_id() {
        assert!(app_peer_is_trusted(
            APP_BUNDLE_IDENTIFIER,
            Some("TEAMID"),
            true,
            Some("TEAMID"),
            true,
        ));
        assert!(!app_peer_is_trusted(
            APP_BUNDLE_IDENTIFIER,
            Some("OTHER"),
            true,
            Some("TEAMID"),
            true,
        ));
        assert!(!app_peer_is_trusted(
            APP_BUNDLE_IDENTIFIER,
            None,
            true,
            Some("TEAMID"),
            true,
        ));
    }

    #[test]
    fn unsigned_daemon_needs_the_explicit_dev_flag() {
        assert!(!app_peer_is_trusted(
            APP_BUNDLE_IDENTIFIER,
            None,
            true,
            None,
            false,
        ));
        assert!(app_peer_is_trusted(
            APP_BUNDLE_IDENTIFIER,
            None,
            true,
            None,
            true,
        ));
    }

    #[test]
    fn a_broken_signature_is_never_trusted() {
        assert!(!app_peer_is_trusted(
            APP_BUNDLE_IDENTIFIER,
            Some("TEAMID"),
            false,
            Some("TEAMID"),
            true,
        ));
    }
}
