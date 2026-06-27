import Foundation
import GoogleSignIn

@MainActor
final class GoogleAuthService: ObservableObject {
    @Published var currentUser: GIDGoogleUser?
    @Published var isSignedIn = false
    @Published var isRestoring = true

    // drive.file is non-sensitive and grants Sheets API access to spreadsheets
    // the app itself created, which is all Kharcha ever touches. Keeping to this
    // single scope avoids Google's restricted-scope verification (CASA).
    private let driveScope = "https://www.googleapis.com/auth/drive.file"

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
            additionalScopes: [driveScope]
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
