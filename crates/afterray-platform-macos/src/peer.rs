//! Identity of a Unix-socket peer.
//!
//! Privilege is never the on-disk path and never “same identifier”. Anyone
//! on this uid can `codesign --sign - --identifier dev.afterray.app` a
//! binary. The daemon instead:
//!
//! 1. Reads the peer audit token (`LOCAL_PEERTOKEN`).
//! 2. Requires a valid `dev.afterray.app` signature.
//! 3. Trusts a matching **Team ID** (Apple Development / Developer ID), or
//!    the **cdhash of the AfterRay process that spawned this daemon**.
//!
//! A fresh ad-hoc signature has a different cdhash, so it cannot satisfy
//! the pin. Ad-hoc daemons started from a shell have no AfterRay parent
//! and grant no privileged clients.

/// Bundle identifier stamped on AfterRay.app.
pub const APP_BUNDLE_IDENTIFIER: &str = "dev.afterray.app";

/// Signing facts used both for a connected peer and for the spawn-time pin.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CodeIdentity {
    pub identifier: String,
    pub team_id: Option<String>,
    pub cdhash: Vec<u8>,
    pub valid: bool,
}

/// Snapshot of the parent process, if it is AfterRay.app. Call once at
/// daemon start — `getppid` later can be recycled.
#[must_use]
pub fn parent_app_anchor() -> Option<CodeIdentity> {
    #[cfg(target_os = "macos")]
    {
        macos::identity_for_pid(u32::try_from(unsafe { libc::getppid() }).ok()?)
            .filter(|identity| identity.valid && identity.identifier == APP_BUNDLE_IDENTIFIER)
    }
    #[cfg(not(target_os = "macos"))]
    {
        None
    }
}

/// `fd` is the accepted connection, not the listening socket.
#[must_use]
pub fn peer_is_afterray_app(fd: i32, anchor: Option<&CodeIdentity>) -> bool {
    #[cfg(target_os = "macos")]
    {
        macos::peer_is_afterray_app(fd, anchor)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (fd, anchor);
        false
    }
}

/// Pure policy so spoof cases are unit tests, not codesign fixtures.
#[must_use]
pub fn app_peer_is_trusted(peer: &CodeIdentity, anchor: Option<&CodeIdentity>) -> bool {
    if !peer.valid || peer.identifier != APP_BUNDLE_IDENTIFIER {
        return false;
    }
    let Some(anchor) = anchor else {
        return false;
    };
    if let (Some(peer_team), Some(anchor_team)) = (&peer.team_id, &anchor.team_id)
        && peer_team == anchor_team
    {
        return true;
    }
    !peer.cdhash.is_empty() && peer.cdhash == anchor.cdhash
}

#[cfg(target_os = "macos")]
mod macos {
    use super::{app_peer_is_trusted, CodeIdentity, APP_BUNDLE_IDENTIFIER};
    use core_foundation::base::{CFRelease, CFType, CFTypeRef, TCFType};
    use core_foundation::data::CFData;
    use core_foundation::dictionary::CFDictionary;
    use core_foundation::number::CFNumber;
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
        static kSecGuestAttributePid: CFStringRef;
        static kSecCodeInfoIdentifier: CFStringRef;
        static kSecCodeInfoTeamIdentifier: CFStringRef;
        static kSecCodeInfoUnique: CFStringRef;

        fn SecCodeCopyGuestWithAttributes(
            host: SecCodeRef,
            attributes: CFTypeRef,
            flags: u32,
            out: *mut SecCodeRef,
        ) -> i32;
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

    pub fn peer_is_afterray_app(fd: i32, anchor: Option<&CodeIdentity>) -> bool {
        let Some(token) = peer_audit_token(fd) else {
            return false;
        };
        let Some(guest) = code_for_audit_token(&token) else {
            return false;
        };
        let Some(info) = signing_info(guest.0) else {
            return false;
        };
        if !app_peer_is_trusted(&info, anchor) {
            return false;
        }
        if let Some(team) = info.team_id.as_deref() {
            return requirement_holds(
                guest.0,
                &format!(
                    r#"identifier "{APP_BUNDLE_IDENTIFIER}" and certificate leaf[subject.OU] = "{team}""#
                ),
            );
        }
        true
    }

    pub fn identity_for_pid(pid: u32) -> Option<CodeIdentity> {
        let pid_number = CFNumber::from(i64::from(pid));
        let key = unsafe { CFString::wrap_under_get_rule(kSecGuestAttributePid) };
        let attributes: CFDictionary<CFString, CFType> =
            CFDictionary::from_CFType_pairs(&[(key, pid_number.as_CFType())]);
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
        let _release = OwnedCf(guest);
        signing_info(guest)
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

    fn signing_info(code: SecCodeRef) -> Option<CodeIdentity> {
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
        let unique_key = unsafe { CFString::wrap_under_get_rule(kSecCodeInfoUnique) };
        let identifier = dict
            .find(&identifier_key)
            .and_then(|value| value.downcast::<CFString>())
            .map(|value| value.to_string())?;
        let team_id = dict
            .find(&team_key)
            .and_then(|value| value.downcast::<CFString>())
            .map(|value| value.to_string())
            .filter(|value| !value.is_empty());
        let cdhash = dict
            .find(&unique_key)
            .and_then(|value| value.downcast::<CFData>())
            .map(|value| value.bytes().to_vec())
            .unwrap_or_default();
        Some(CodeIdentity {
            identifier,
            team_id,
            cdhash,
            valid,
        })
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
    use super::{app_peer_is_trusted, CodeIdentity, APP_BUNDLE_IDENTIFIER};

    fn identity(
        identifier: &str,
        team_id: Option<&str>,
        cdhash: &[u8],
        valid: bool,
    ) -> CodeIdentity {
        CodeIdentity {
            identifier: identifier.to_owned(),
            team_id: team_id.map(ToOwned::to_owned),
            cdhash: cdhash.to_vec(),
            valid,
        }
    }

    #[test]
    fn a_forged_adhoc_identifier_is_not_enough() {
        let parent = identity(APP_BUNDLE_IDENTIFIER, None, &[0xAA, 0xBB], true);
        let forged = identity(APP_BUNDLE_IDENTIFIER, None, &[0x00, 0x01], true);
        assert!(
            !app_peer_is_trusted(&forged, Some(&parent)),
            "codesign -s - --identifier dev.afterray.app must not match the parent pin"
        );
    }

    #[test]
    fn adhoc_parent_pin_accepts_the_same_cdhash() {
        let parent = identity(APP_BUNDLE_IDENTIFIER, None, &[0xAA, 0xBB], true);
        let peer = identity(APP_BUNDLE_IDENTIFIER, None, &[0xAA, 0xBB], true);
        assert!(app_peer_is_trusted(&peer, Some(&parent)));
    }

    #[test]
    fn no_anchor_means_nobody_is_privileged() {
        let peer = identity(APP_BUNDLE_IDENTIFIER, None, &[0xAA], true);
        assert!(!app_peer_is_trusted(&peer, None));
    }

    #[test]
    fn matching_team_ids_are_enough() {
        let anchor = identity(APP_BUNDLE_IDENTIFIER, Some("TEAMID"), &[0x01], true);
        let peer = identity(APP_BUNDLE_IDENTIFIER, Some("TEAMID"), &[0x99], true);
        assert!(app_peer_is_trusted(&peer, Some(&anchor)));
        let other = identity(APP_BUNDLE_IDENTIFIER, Some("OTHER"), &[0x02], true);
        assert!(!app_peer_is_trusted(&other, Some(&anchor)));
    }

    #[test]
    fn empty_cdhashes_do_not_collapse_to_a_match() {
        let anchor = identity(APP_BUNDLE_IDENTIFIER, None, &[], true);
        let peer = identity(APP_BUNDLE_IDENTIFIER, None, &[], true);
        assert!(!app_peer_is_trusted(&peer, Some(&anchor)));
    }

    #[test]
    fn a_broken_signature_is_never_trusted() {
        let anchor = identity(APP_BUNDLE_IDENTIFIER, Some("TEAMID"), &[0x01], true);
        let peer = identity(APP_BUNDLE_IDENTIFIER, Some("TEAMID"), &[0x01], false);
        assert!(!app_peer_is_trusted(&peer, Some(&anchor)));
    }

    #[test]
    fn the_cli_identifier_is_never_the_app() {
        let anchor = identity(APP_BUNDLE_IDENTIFIER, Some("TEAMID"), &[0x01], true);
        let cli = identity("afterray", Some("TEAMID"), &[0x01], true);
        assert!(!app_peer_is_trusted(&cli, Some(&anchor)));
    }
}
