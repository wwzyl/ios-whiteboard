import Foundation

struct CBrainNode: Identifiable, Hashable {
    var id: String
    var topic: String
    var fileName: String
    var status: String

    var isActive: Bool {
        status != "0"
    }
}

struct CBrainLink: Identifiable {
    var id: String
    var nodeId1: String
    var nodeId2: String
    var linkType: String
    var status: String

    var isActive: Bool {
        status != "0"
    }
}

struct CBrainSearchResult: Identifiable {
    var id: String { nodeId }
    var nodeId: String
    var title: String
    var reason: String
}

struct CBrainFileRecord {
    var path: String
    var size: Int64
    var modifiedTime: Int64
}

enum CBrainError: LocalizedError {
    case missingLibrary
    case invalidLibrary
    case nodeNotFound
    case message(String)

    var errorDescription: String? {
        switch self {
        case .missingLibrary:
            return "还没有导入知识库"
        case .invalidLibrary:
            return "选择的文件夹不是 CBrain 知识库，需要包含 graph.json 和 notes 文件夹"
        case .nodeNotFound:
            return "节点不存在"
        case .message(let text):
            return text
        }
    }
}
