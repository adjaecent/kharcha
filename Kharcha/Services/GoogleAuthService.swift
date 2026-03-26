import Foundation
import GoogleSignIn

@MainActor
final class GoogleAuthService: ObservableObject {
    @Published var currentUser: GIDGoogleUser?
    @Published var isSignedIn = false
    @Published var isRestoring = true

    private let driveScope = "https://www.googleapis.com/auth/drive.file"
    private let sheetsScope = "https://www.googleapis.com/auth/spreadsheets"

    var accessToken: String? {
        currentUser?.accessToken.tokenString
    }

    func restorePreviousSignIn() async {
        defer { isRestoring = false }
        do {
            let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
            currentUser = user
            isSignedIn = true
        } catch {
            currentUser = nil
            isSignedIn = false
        }
    }

    func signIn(presenting viewController: UIViewController) async throws {
        let result = try await GIDSignIn.sharedInstance.signIn(
            withPresenting: viewController,
            hint: nil,
            additionalScopes: [driveScope, sheetsScope]
        )
        currentUser = result.user
        isSignedIn = true
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        currentUser = nil
        isSignedIn = false
    }

    func refreshTokenIfNeeded() async throws {
        guard let user = currentUser else { return }
        if user.accessToken.expirationDate ?? Date.distantPast < Date() {
            try await user.refreshTokensIfNeeded()
        }
    }
}
