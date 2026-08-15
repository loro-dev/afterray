import AfterRayMlxVlmWorkerCore
import Foundation

@main
struct AfterRayMlxVlmWorkerMain {
    static func main() async {
        let worker = MlxWorker()
        while let line = readLine(strippingNewline: true) {
            await worker.accept(line: line)
        }
    }
}
