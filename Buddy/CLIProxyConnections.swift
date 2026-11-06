import Foundation
import BuddyCore
import Combine

extension Provider {
    var preferredModel: String { self == .claude ? "claude-sonnet-4-6" : "gpt-6.1-sol" }
    /// The small fast models the utility process prefers, best first.
    var utilityModels: [String] { self == .claude ? ["claude-haiku-5-5", "claude-haiku-4-5-20251001"] : ["gpt-6-luna", "gpt-5.6-luna"] }
}

struct TalkSelection: Codable {
    var useProxy = true
    /// The provider CLIProxy serves, whose accounts and models the other fields choose from.
    var provider = Provider.claude
    var accountID = ""
    var model = Provider.claude.preferredModel
    /// Which provider answers with direct sign-ins.
    var choice = ProviderChoice.auto

    init() {}

    /// A selection saved before `choice` existed starts on Auto.
    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        useProxy = try fields.decode(Bool.self, forKey: .useProxy)
        provider = try fields.decode(Provider.self, forKey: .provider)
        accountID = try fields.decode(String.self, forKey: .accountID)
        model = try fields.decode(String.self, forKey: .model)
        choice = try fields.decodeIfPresent(ProviderChoice.self, forKey: .choice) ?? .auto
    }
}

/// The account and model last chosen for a provider.
struct TalkPick: Codable {
    var accountID: String
    var model: String
}

struct ProxyAccount: Decodable, Identifiable {
    let name: String
    let authIndex: String
    let provider: String
    let disabled: Bool
    let label: String?
    let email: String?
    let status: String?
    let nextRetryAfter: String?
    var models: [String] = []

    var id: String { authIndex }
    var title: String { [label, email].compactMap { $0 }.first { !$0.isEmpty } ?? name }
    var modelNames: [String] { Array(Set(models.map { String($0.split(separator: "/").last ?? "") })).sorted() }
    var statusText: String? {
        if disabled { return "Disabled in CLIProxy." }
        guard status == "error" else { return nil }
        if let nextRetryAfter, let date = ISO8601DateFormatter().date(from: nextRetryAfter), date > Date() {
            return "Limited or unavailable. Retry after \(date.formatted(date: .abbreviated, time: .shortened))."
        }
        return "CLIProxy reports this account as unavailable. Choose another account or provider."
    }

    enum CodingKeys: String, CodingKey {
        case name, provider, disabled, label, email, status
        case authIndex = "auth_index", nextRetryAfter = "next_retry_after"
    }
}

final class CLIProxyClient {
    struct Configuration: Equatable {
        let origin: URL
        let accessKey: String
        let managementKey: String

        static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Configuration {
            struct Settings: Decodable { let env: [String: String] }
            let settings = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: home.appending(path: ".claude/settings.json")))
            guard let address = settings.env["ANTHROPIC_BASE_URL"],
                  let url = URL(string: address), let host = url.host,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))
            else { throw ConnectionError("CLIProxy needs an HTTPS address or a local HTTP address in Claude settings.") }
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            parts.path = ""
            let folder = home.appending(path: ".config/cliproxyapi")
            let access = (try? String(contentsOf: folder.appending(path: "access-key"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? settings.env["ANTHROPIC_AUTH_TOKEN"] ?? ""
            let management = try String(contentsOf: folder.appending(path: "management-key"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !access.isEmpty, !management.isEmpty else { throw ConnectionError("CLIProxy's local access and management keys are missing.") }
            return Configuration(origin: parts.url!, accessKey: access, managementKey: management)
        }
    }

    let configuration: Configuration
    private let session: URLSession

    init(configuration: Configuration) {
        self.configuration = configuration
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 15
        settings.timeoutIntervalForResource = 30
        settings.urlCache = nil
        settings.httpCookieStorage = nil
        session = URLSession(configuration: settings, delegate: NoProxyRedirects(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func accounts() async throws -> [ProxyAccount] {
        struct Listing: Decodable { let files: [ProxyAccount] }
        var accounts = try JSONDecoder().decode(Listing.self, from: await request("auth-files")).files
            .filter { Provider(rawValue: $0.provider) != nil }
        for index in accounts.indices {
            struct Models: Decodable {
                struct Model: Decodable { let id: String }
                let models: [Model]
            }
            accounts[index].models = try JSONDecoder().decode(Models.self, from: await request(
                "auth-files/models", query: [URLQueryItem(name: "name", value: accounts[index].name)]
            )).models.map(\.id)
        }
        return accounts
    }

    func prepareAccount(_ id: String, model: String) async throws -> [ProxyAccount] {
        let current = try await accounts()
        guard let account = current.first(where: { $0.id == id }), !account.disabled else {
            throw ConnectionError("This account is no longer available in CLIProxy. Choose another account.")
        }
        if try Self.route(account: account, model: model, accounts: current) != nil { return current }
        guard account.models.allSatisfy({ !$0.contains("/") }), account.models.contains(model) else {
            throw ConnectionError("This account needs a unique model prefix in CLIProxy before Buddy can select it.")
        }
        let flags = try JSONSerialization.jsonObject(with: await request("force-model-prefix")) as? [String: Bool]
        guard flags?["force-model-prefix"] == false else {
            throw ConnectionError("CLIProxy requires model prefixes. Configure a unique account prefix there first.")
        }
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw ConnectionError("CLIProxy returned an unsupported account identifier.")
        }
        let prefix = "buddy-\(id)"
        guard !current.contains(where: { $0.models.contains { $0.hasPrefix(prefix + "/") } }) else {
            throw ConnectionError("This account's Buddy alias is already in use by another account.")
        }
        _ = try await request("auth-files/fields", method: "PATCH", body: ["name": account.name, "prefix": prefix])
        let updated = try await accounts()
        guard let refreshed = updated.first(where: { $0.id == id }),
              try Self.route(account: refreshed, model: model, accounts: updated) != nil else {
            throw ConnectionError("CLIProxy has not published the account alias yet. Refresh and try again.")
        }
        return updated
    }

    static func route(account: ProxyAccount, model: String, accounts: [ProxyAccount]) throws -> String? {
        let candidates = account.models.filter { $0.contains("/") && $0.hasSuffix("/" + model) }
        guard let route = candidates.first else { return nil }
        guard accounts.filter({ $0.models.contains(route) }).count == 1 else {
            throw ConnectionError("This model alias is shared by multiple accounts. Choose a unique prefix in CLIProxy.")
        }
        return route
    }

    private func request(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: [String: String]? = nil) async throws -> Data {
        var parts = URLComponents(url: configuration.origin.appending(path: "v0/management/\(path)"), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        var request = URLRequest(url: parts.url!)
        request.httpMethod = method
        request.setValue("Bearer \(configuration.managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw ConnectionError("CLIProxy couldn't be reached. Check its connection, then refresh.") }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ConnectionError("CLIProxy rejected the request (HTTP \(code)). Check its connection and local keys.")
        }
        return data
    }
}

struct ConnectionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class NoProxyRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class TalkConnections: ObservableObject {
    @Published private(set) var selection: TalkSelection
    @Published private(set) var accounts: [ProxyAccount] = []
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    var onChange: (() -> Void)?
    private var client: CLIProxyClient?
    private let defaults: UserDefaults
    private let loadConfiguration: @MainActor () throws -> CLIProxyClient.Configuration
    /// The account and model each provider had when the owner last switched away from it, by provider.
    private var picks: [String: TalkPick]
    private static let selectionKey = "talkConnectionV1"
    private static let picksKey = "talkPicksV1"

    init(defaults: UserDefaults = .standard, loadConfiguration: @escaping @MainActor () throws -> CLIProxyClient.Configuration = { try .load() }) {
        self.defaults = defaults
        self.loadConfiguration = loadConfiguration
        let saved = defaults.data(forKey: Self.selectionKey).flatMap { try? JSONDecoder().decode(TalkSelection.self, from: $0) }
        var selection = saved ?? TalkSelection()
        if saved == nil { selection.useProxy = (try? loadConfiguration()) != nil }
        self.selection = selection
        picks = defaults.data(forKey: Self.picksKey).flatMap { try? JSONDecoder().decode([String: TalkPick].self, from: $0) } ?? [:]
    }

    var providerAccounts: [ProxyAccount] { accounts.filter { $0.provider == selection.provider.rawValue } }
    var selectedAccount: ProxyAccount? { providerAccounts.first { $0.id == selection.accountID } }
    var models: [String] {
        if !selection.accountID.isEmpty { return selectedAccount?.modelNames ?? [] }
        return Array(Set(providerAccounts.filter { !$0.disabled }.flatMap(\.models).filter { !$0.contains("/") })).sorted()
    }
    var unavailableReason: String? {
        guard selection.useProxy else { return nil }
        if busy { return "CLIProxy accounts are loading or switching. Try again in a moment." }
        if let error { return error }
        guard client != nil else { return "Refresh CLIProxy before asking a question." }
        guard models.contains(selection.model) else { return "Choose an available account and model in Buddy's settings." }
        if !selection.accountID.isEmpty {
            guard let account = selectedAccount, !account.disabled,
                  (try? CLIProxyClient.route(account: account, model: selection.model, accounts: accounts)) != nil else {
                return "The selected account isn't ready. Select it again or choose another account."
            }
        }
        return nil
    }

    /// With direct sign-ins the engine routes between both providers. Through CLIProxy, the chosen provider speaks
    /// Claude Code's transport.
    var setup: TalkSetup { selection.useProxy ? .proxied(selection.provider) : .direct(selection.choice) }

    var proxy: ClaudeProxy? {
        guard selection.useProxy, unavailableReason == nil, let client else { return nil }
        var model = selection.model
        if let account = selectedAccount {
            guard let route = try? CLIProxyClient.route(account: account, model: model, accounts: accounts) else { return nil }
            model = route
        }
        return ClaudeProxy(baseURL: client.configuration.origin.absoluteString, token: client.configuration.accessKey, model: model)
    }

    /// The talk proxy with the selected provider's small model on the same account and hub. When the account offers
    /// none of them, or can't route one, it keeps the talk model rather than leave that account.
    var utilityProxy: ClaudeProxy? {
        guard let proxy else { return nil }
        let offered = selectedAccount?.modelNames ?? models
        guard let model = selection.provider.utilityModels.first(where: offered.contains) else { return proxy }
        guard let account = selectedAccount else { return ClaudeProxy(baseURL: proxy.baseURL, token: proxy.token, model: model) }
        guard let route = try? CLIProxyClient.route(account: account, model: model, accounts: accounts) else { return proxy }
        return ClaudeProxy(baseURL: proxy.baseURL, token: proxy.token, model: route)
    }

    func refresh() async {
        guard !busy else { return }
        let previousProxy = proxy
        busy = true
        defer { busy = false }
        do {
            let client = CLIProxyClient(configuration: try loadConfiguration())
            let accounts = try await client.accounts()
            let credentialsChanged = self.client?.configuration != client.configuration
            self.client = client
            self.accounts = accounts
            error = nil
            busy = false
            if credentialsChanged || previousProxy != proxy { onChange?() }
        } catch { self.error = (error as? ConnectionError)?.message ?? "CLIProxy's local settings or keys couldn't be read." }
    }

    func useProxy(_ enabled: Bool) {
        selection.useProxy = enabled
        save()
    }

    func choose(_ choice: ProviderChoice) {
        selection.choice = choice
        save()
    }

    /// Switching back to a provider brings back the account and model last chosen for it.
    func chooseProvider(_ provider: Provider) {
        guard provider != selection.provider else { return }
        picks[selection.provider.rawValue] = TalkPick(accountID: selection.accountID, model: selection.model)
        selection.provider = provider
        if let pick = picks[provider.rawValue] {
            selection.accountID = pick.accountID
            selection.model = pick.model
        } else {
            selection.accountID = ""
            selection.model = models.isEmpty || models.contains(provider.preferredModel) ? provider.preferredModel : models[0]
        }
        defaults.set(try? JSONEncoder().encode(picks), forKey: Self.picksKey)
        save()
    }

    func chooseAccount(_ id: String) async {
        guard !busy, let client else { return }
        busy = true
        defer { busy = false }
        do {
            var model = selection.model
            if !id.isEmpty {
                if let account = providerAccounts.first(where: { $0.id == id }), !account.modelNames.contains(model) {
                    model = account.modelNames.contains(selection.provider.preferredModel)
                        ? selection.provider.preferredModel : account.modelNames.first ?? ""
                }
                accounts = try await client.prepareAccount(id, model: model)
            }
            selection.accountID = id
            selection.model = model
            error = nil
            save()
        } catch { self.error = (error as? ConnectionError)?.message ?? "This CLIProxy account couldn't be selected." }
    }

    func chooseModel(_ model: String) {
        guard models.contains(model) else { return }
        selection.model = model
        save()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(selection), forKey: Self.selectionKey)
        onChange?()
    }
}
