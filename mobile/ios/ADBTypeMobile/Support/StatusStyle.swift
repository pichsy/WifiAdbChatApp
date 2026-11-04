import SwiftUI

extension LANStatusKind {
    var color: Color {
        switch self {
        case .idle:
            return .secondary
        case .success:
            return .green
        case .failure:
            return .red
        }
    }
}
