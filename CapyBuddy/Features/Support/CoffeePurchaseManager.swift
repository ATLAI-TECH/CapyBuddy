import Foundation
import StoreKit

/// Three consumable IAP tiers shown on the "Buy me a coffee" page.
/// Product IDs must match the entries created in App Store Connect (or the
/// local .storekit configuration used during development). If products fail
/// to load (e.g. before App Store Connect is configured) the UI gracefully
/// falls back to a "Loading…" / "Unavailable" state so the page still
/// renders.
enum CoffeeTier: String, CaseIterable, Identifiable {
    case small  = "com.atlai.capybuddy.coffee.small"
    case medium = "com.atlai.capybuddy.coffee.medium"
    case large  = "com.atlai.capybuddy.coffee.large"

    var id: String { rawValue }

    /// Display name shown on the tile, independent of the App Store
    /// product name so the UI still renders before products load.
    var displayName: String {
        switch self {
        case .small:  return "Espresso"
        case .medium: return "Latte"
        case .large:  return "Latte + Waffle"
        }
    }

    /// SF Symbols rendered as the tile's hero glyph(s). The large tier
    /// shows two icons side-by-side to convey the combo. SF Symbols has
    /// no dedicated waffle glyph, so the grid square stands in for the
    /// waffle's pattern.
    var symbols: [String] {
        switch self {
        case .small:  return ["cup.and.saucer"]
        case .medium: return ["cup.and.saucer.fill"]
        case .large:  return ["cup.and.saucer.fill", "square.grid.3x3.fill"]
        }
    }

    /// Fallback price string used only when the StoreKit product hasn't
    /// loaded yet. The real price comes from `Product.displayPrice` once
    /// products resolve from the App Store.
    var fallbackPrice: String {
        switch self {
        case .small:  return "$1.99"
        case .medium: return "$4.99"
        case .large:  return "$9.99"
        }
    }
}

@MainActor
final class CoffeePurchaseManager: ObservableObject {

    enum State: Equatable {
        case idle
        case loading
        case ready
        case unavailable(String)
    }

    enum PurchaseState: Equatable {
        case idle
        case purchasing(CoffeeTier)
        case succeeded(CoffeeTier)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var purchaseState: PurchaseState = .idle
    @Published private(set) var products: [CoffeeTier: Product] = [:]

    private var transactionListener: Task<Void, Never>?

    init() {
        // StoreKit 2 delivers transactions on `Transaction.updates` — we
        // must subscribe at launch so transactions completed outside the
        // app (Ask-to-Buy approvals, family sharing, refunds) get
        // finalized rather than re-delivered every launch.
        transactionListener = Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard case .verified(let transaction) = result else { continue }
                await transaction.finish()
                guard let tier = CoffeeTier(rawValue: transaction.productID) else { continue }
                await self?.markSucceeded(tier: tier)
            }
        }
    }

    deinit {
        transactionListener?.cancel()
    }

    private func markSucceeded(tier: CoffeeTier) {
        purchaseState = .succeeded(tier)
    }

    func loadProducts() async {
        if case .loading = state { return }
        state = .loading
        do {
            let fetched = try await Product.products(for: CoffeeTier.allCases.map(\.rawValue))
            var map: [CoffeeTier: Product] = [:]
            for product in fetched {
                if let tier = CoffeeTier(rawValue: product.id) {
                    map[tier] = product
                }
            }
            products = map
            if map.isEmpty {
                state = .unavailable("Tip jar is not configured yet.")
            } else {
                state = .ready
            }
        } catch {
            state = .unavailable(error.localizedDescription)
        }
    }

    func purchase(_ tier: CoffeeTier) async {
        guard let product = products[tier] else {
            purchaseState = .failed("Product not loaded.")
            return
        }
        purchaseState = .purchasing(tier)
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    purchaseState = .succeeded(tier)
                } else {
                    purchaseState = .failed("Could not verify purchase.")
                }
            case .userCancelled:
                purchaseState = .idle
            case .pending:
                purchaseState = .failed("Purchase is pending approval.")
            @unknown default:
                purchaseState = .idle
            }
        } catch {
            purchaseState = .failed(error.localizedDescription)
        }
    }

    func dismissPurchaseResult() {
        purchaseState = .idle
    }
}
