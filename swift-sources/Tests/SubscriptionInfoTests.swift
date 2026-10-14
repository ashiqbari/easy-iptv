import XCTest
@testable import EasyIPTV

final class SubscriptionInfoTests: XCTestCase {
    func testExpiryAcceptsStringAndNumericTimestampsAndRejectsUnknownValues() throws {
        for value in ["\"1800000000\"", "1800000000"] {
            let info = try JSONDecoder().decode(XtreamUserInfo.self, from: Data("{\"exp_date\":\(value),\"active_cons\":1,\"max_connections\":\"2\",\"auth\":\"1\"}".utf8))
            XCTAssertEqual(info.expiryDate, Date(timeIntervalSince1970: 1_800_000_000))
            XCTAssertEqual(info.activeCons, "1")
            XCTAssertEqual(info.maxConnections, "2")
            XCTAssertEqual(info.auth, 1)
        }
        for value in ["null", "0", "\"0\"", "-1", "\"unknown\"", "\"nan\"", "\"inf\"", "\"9999999999999999999999\""] {
            let info = try JSONDecoder().decode(XtreamUserInfo.self, from: Data("{\"exp_date\":\(value)}".utf8))
            XCTAssertNil(info.expiryDate)
        }
        for invalid in [#"{"auth":true}"#, #"{"auth":"invalid"}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(XtreamUserInfo.self, from: Data(invalid.utf8)))
        }
        let expired = try JSONDecoder().decode(XtreamUserInfo.self, from: Data(#"{"exp_date":"1000000000","status":"Expired","auth":0}"#.utf8))
        XCTAssertEqual(expired.status, "Expired")
        XCTAssertEqual(expired.expiryDate, Date(timeIntervalSince1970: 1_000_000_000))
        XCTAssertNil(try JSONDecoder().decode(XtreamUserInfo.self, from: Data("{}".utf8)).expiryDate)
    }

    func testCompatiblePlaylistPreservesProviderSubpathAndDecodedCredentials() throws {
        let account = try XCTUnwrap(SubscriptionAccount(playlistURL: "https://provider.example:8443/iptv/get.php?username=a%2Bb&password=p%26%3F&type=m3u_plus#ignored"))
        XCTAssertEqual(account.serverURL, "https://provider.example:8443/iptv")
        XCTAssertEqual(account.username, "a+b")
        XCTAssertEqual(account.password, "p&?")
        for url in ["https://provider.example/playlist.m3u?expires=1800000000",
                    "https://provider.example/get.php?username=only",
                    "https://provider.example/get.php?username=a&username=b&password=p",
                    "file:///get.php?username=a&password=p",
                    "https://provider.example/get.php?username=&password=p"] {
            XCTAssertNil(SubscriptionAccount(playlistURL: url))
        }
    }

    @MainActor func testInformationUsesSavedSourceInsteadOfFormDraftsAndClearsWhenSourceChanges() async throws {
        let suite = "subscription-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        var loader = LibraryLoader()
        let response = try JSONDecoder().decode(XtreamAuthResponse.self, from: Data(#"{"user_info":{"exp_date":"1800000000","status":"Active"}}"#.utf8))
        loader.account = { server, username, password in
            XCTAssertEqual(server, "https://provider.example")
            XCTAssertEqual(username, "saved-user")
            XCTAssertEqual(password, "saved-password")
            return response
        }
        loader.live = { _, _, _ in [] }
        loader.movies = { _, _, _ in [] }
        loader.series = { _, _, _ in [] }
        loader.playlist = { _ in [] }
        let manager = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
        defer {
            manager.stop()
            manager.libraryPersistence.invalidatePendingWrites()
            defaults.removePersistentDomain(forName: suite)
        }
        await manager.loadXtream(serverURL: "https://provider.example", username: "saved-user", password: "saved-password")
        manager.xtreamServerURL = "https://different.example"
        manager.xtreamUsername = "draft-user"
        manager.xtreamPassword = "draft-password"
        let account = try XCTUnwrap(manager.subscriptionAccount)
        let info = try await manager.subscriptionInformation(for: account)
        XCTAssertEqual(info.expiryDate, Date(timeIntervalSince1970: 1_800_000_000))
        await manager.loadPlaylist(from: "https://other.example/playlist.m3u")
        XCTAssertNil(manager.subscriptionAccount)
        await manager.loadPlaylist(from: "https://other.example/get.php?username=next&password=secret")
        XCTAssertEqual(manager.subscriptionAccount?.username, "next")
        manager.clearAllData()
        XCTAssertNil(manager.subscriptionAccount)
    }
    @MainActor func testCacheSurvivesRestartRefreshesOnDemandAndDoesNotCrossAccounts() async throws {
        let suite = "subscription-cache-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let account = SubscriptionAccount(serverURL: "https://provider.example", username: "private-account-name", password: "private-password-value")
        defaults.set(["server": account.serverURL, "username": account.username, "password": account.password], forKey: "com.iptvplayer.savedXtream")
        let provider = SubscriptionProvider()
        var loader = LibraryLoader()
        loader.account = { _, _, _ in try await provider.load() }
        let manager = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
        let restarted = IPTVPlayerManager(progressDefaults: defaults, libraryLoader: loader)
        defer { manager.stop(); restarted.stop(); defaults.removePersistentDomain(forName: suite) }
        let first = try await manager.subscriptionInformation(for: account)
        let cached = try await restarted.subscriptionInformation(for: account)
        XCTAssertEqual(cached.updatedAt, first.updatedAt)
        let initialCalls = await provider.calls
        XCTAssertEqual(initialCalls, 1)
        let saved = try XCTUnwrap(defaults.data(forKey: SubscriptionInfo.storageKey))
        let json = String(decoding: saved, as: UTF8.self)
        for secret in [account.username, account.password, account.serverURL] { XCTAssertFalse(json.contains(secret)) }

        let refreshed = try await restarted.subscriptionInformation(for: account, refresh: true)
        XCTAssertEqual(refreshed.expiryDate, Date(timeIntervalSince1970: 1_900_000_000))
        do {
            _ = try await manager.subscriptionInformation(for: account, refresh: true)
            XCTFail("Expected refresh failure")
        } catch { }
        let retained = try await manager.subscriptionInformation(for: account)
        XCTAssertEqual(retained.updatedAt, refreshed.updatedAt)
        let callsAfterFailure = await provider.calls
        XCTAssertEqual(callsAfterFailure, 3)

        let changed = SubscriptionAccount(serverURL: account.serverURL, username: account.username, password: "different-password")
        defaults.set(["server": changed.serverURL, "username": changed.username, "password": changed.password], forKey: "com.iptvplayer.savedXtream")
        XCTAssertNotEqual(changed.cacheID, account.cacheID)
        _ = try await manager.subscriptionInformation(for: changed)
        let changedCalls = await provider.calls
        XCTAssertEqual(changedCalls, 4)
        defaults.set(Data("invalid cache".utf8), forKey: SubscriptionInfo.storageKey)
        _ = try await manager.subscriptionInformation(for: changed)
        let recoveredCalls = await provider.calls
        XCTAssertEqual(recoveredCalls, 5)
        manager.clearAllData()
        XCTAssertNil(defaults.data(forKey: SubscriptionInfo.storageKey))
        _ = try await manager.subscriptionInformation(for: changed)
        XCTAssertNil(defaults.data(forKey: SubscriptionInfo.storageKey), "A stale request must not restore cleared account details")
    }

}


private actor SubscriptionProvider {
    private(set) var calls = 0
    func load() throws -> XtreamAuthResponse {
        calls += 1
        if calls == 3 { throw URLError(.notConnectedToInternet) }
        let expiry = calls == 1 ? 1_800_000_000 : 1_900_000_000
        return try JSONDecoder().decode(XtreamAuthResponse.self, from: Data("{\"user_info\":{\"status\":\"Active\",\"exp_date\":\(expiry)}}".utf8))
    }
}
