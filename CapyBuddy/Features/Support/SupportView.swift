import AppKit
import StoreKit
import SwiftUI

/// "Buy me a coffee" + cross-promo page. Shown as the bottom sidebar entry
/// in Settings. Two sections:
///   1. Three consumable IAP tiles (Espresso / Latte / Latte + Waffle).
///   2. A promo card for our other app, TermBuddy, that opens its
///      website / App Store page in the user's default browser.
struct SupportView: View {

    @StateObject private var purchases = CoffeePurchaseManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            CoffeeSection(purchases: purchases)
            TermBuddyPromoCard()
            Spacer()
        }
        .task { await purchases.loadProducts() }
    }
}

// MARK: - Coffee tiles

private struct CoffeeSection: View {
    @ObservedObject var purchases: CoffeePurchaseManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Buy me a coffee")
                    .font(.title2).bold()
                Text("☕")
                Spacer()
            }
            Text("If CapyBuddy saves you a few minutes a day, consider tipping the developer. One-time purchases - no subscriptions, no accounts.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                ForEach(CoffeeTier.allCases) { tier in
                    CoffeeTile(tier: tier, purchases: purchases)
                }
            }
            .padding(.top, 4)

            availabilityFooter
            statusFooter
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .quaternarySystemFill))
        )
    }

    /// Surface the product-loading state. Without this, a failed load in
    /// the App Store sandbox just leaves every Buy button disabled with no
    /// explanation (App Review rejected 1.0.0 (2) for exactly that).
    @ViewBuilder
    private var availabilityFooter: some View {
        switch purchases.state {
        case .loading where purchases.products.isEmpty:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading prices…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .unavailable(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Retry") {
                    Task { await purchases.loadProducts() }
                }
                .controlSize(.small)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var statusFooter: some View {
        switch purchases.purchaseState {
        case .idle:
            EmptyView()
        case .purchasing(let tier):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Processing \(tier.displayName)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .succeeded(let tier):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Thank you for the \(tier.displayName)! ❤️")
                    .font(.caption)
                Spacer()
                Button("Dismiss") { purchases.dismissPurchaseResult() }
                    .controlSize(.small)
            }
        case .failed(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Dismiss") { purchases.dismissPurchaseResult() }
                    .controlSize(.small)
            }
        }
    }
}

private struct CoffeeTile: View {
    let tier: CoffeeTier
    @ObservedObject var purchases: CoffeePurchaseManager

    private var product: Product? { purchases.products[tier] }

    private var priceText: String {
        product?.displayPrice ?? tier.fallbackPrice
    }

    private var isBusy: Bool {
        if case .purchasing(let t) = purchases.purchaseState, t == tier { return true }
        return false
    }

    private var isDisabled: Bool {
        if case .purchasing = purchases.purchaseState { return true }
        return product == nil
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(tier.symbols, id: \.self) { name in
                    Image(systemName: name)
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(.brown)
                }
            }
            .frame(height: 36)

            Text(tier.displayName)
                .font(.headline)

            Text(priceText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button {
                Task { await purchases.purchase(tier) }
            } label: {
                Group {
                    if isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Buy")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(isDisabled)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

// MARK: - TermBuddy promo

private struct TermBuddyPromoCard: View {

    private static let termBuddyURL = URL(string: "https://termbuddy.atlai.co.uk/")!
    private static let supportURL = URL(string: "https://capybuddy.atlai.co.uk/")!

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CapyBuddy is built by TermBuddy")
                .font(.headline)
                .foregroundStyle(.secondary)

            HStack(alignment: .center, spacing: 14) {
                Image("TermBuddyLogo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text("TermBuddy")
                        .font(.title3).bold()
                    Text("Make your terminal go “lobster.” The next-gen AI chat-first IDE - chat from your phone or Mac, let the server do the work.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Button {
                    NSWorkspace.shared.open(Self.termBuddyURL)
                } label: {
                    Label("Get it", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }

            Divider()
                .padding(.vertical, 2)

            HStack(spacing: 6) {
                Text("For more information and support, visit")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    NSWorkspace.shared.open(Self.supportURL)
                } label: {
                    Text("capybuddy.atlai.co.uk")
                        .font(.callout)
                }
                .buttonStyle(.link)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .quaternarySystemFill))
        )
    }
}
