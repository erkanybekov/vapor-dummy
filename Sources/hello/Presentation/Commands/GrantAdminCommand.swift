import Vapor

// MARK: - Grant Admin Command
//
//   swift run hello grant-admin someone@example.com
//   swift run hello grant-admin someone@example.com --revoke
//
// The first admin has to come from here. An email list in the environment would not
// be safe: emails are not verified, so whoever registers the address first would get
// the role. This command only touches an account that already exists.

struct GrantAdminCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Argument(name: "email", help: "Email of an existing account")
        var email: String

        @Flag(name: "revoke", help: "Take the role away instead")
        var revoke: Bool
    }

    var help: String { "Gives an existing account access to the admin panel" }

    func run(using context: CommandContext, signature: Signature) async throws {
        guard let repository = context.application.userRepository else {
            throw Abort(.internalServerError, reason: "UserRepository not configured")
        }
        // A typo is not a crash: an error thrown from here would trap in the entrypoint.
        guard let user = try await repository.find(by: signature.email) else {
            context.console.error("No account with email \(signature.email): register it first")
            return
        }

        _ = try await repository.update(user.with(isAdmin: !signature.revoke))
        context.console.success("\(user.email) is \(signature.revoke ? "no longer" : "now") an admin")
    }
}
