// yapbay.move
// The YapBay Sequential Escrow Contract implements a secure escrow mechanism for
// both P2P and chained remittance trades using USDC on the Sui blockchain.
// This module enforces rules for deposit, fiat confirmation, release, cancellation,
// and dispute handling as specified in the contract requirements document.

module yapbay::sequential_escrow {

    // === IMPORTS ===
    // Standard Sui framework imports
    // use sui::object::{Self, ID, UID};
    // use sui::transfer;
    // use sui::tx_context::{Self, TxContext};
    // use std::option::{Self, Option};

    use sui::coin::{Self, Coin};
    use sui::clock::{Self, Clock};
    use sui::event;
    use std::string::{Self, String};
    use usdc::usdc::USDC;

    // === ERRORS ===
    // Error codes as specified in section 7 of the requirements document
    const E100: u64 = 100; // Invalid amount: Zero or negative
    const E101: u64 = 101; // Amount exceeds maximum (100 USDC)
    const E102: u64 = 102; // Unauthorized caller
    const E103: u64 = 103; // Deposit deadline expired
    const E104: u64 = 104; // Fiat payment deadline expired
    const E105: u64 = 105; // Invalid state transition
    const E106: u64 = 106; // Missing sequential escrow address
    const E107: u64 = 107; // Already in terminal state

    // === CONSTANTS ===
    // Maximum amount allowed (100 USDC) as specified in section 1
    const MAX_AMOUNT: u64 = 100_000_000; // 6 decimals for USDC
    
    // Deadlines as specified in section 1
    const DEPOSIT_DEADLINE_MINUTES: u64 = 15; // 15 minutes from order initiation
    const FIAT_DEADLINE_MINUTES: u64 = 30;    // 30 minutes after funding
    
    // Arbitrator address from section 1
    const ARBITRATOR_ADDRESS: address = @0x4ac605c28e73b516db9d0bf4caf538790558a73d7ce6b837fb69449eebfb431d;

    // === STRUCTS ===
    // Escrow state enum as defined in section 3
    // Adding copy and drop abilities to allow comparisons and state transitions
    public enum EscrowState has copy, drop, store {
        Created,
        Funded,
        Released,
        Cancelled,
        Disputed,
        Resolved
    }

    // Main escrow struct as specified in section 3
    public struct Escrow has key, store {
        id: UID,
        escrow_id: u64,
        trade_id: u64,
        seller: address,
        buyer: address,
        arbitrator: address,
        amount: u64,
        deposit_deadline: u64,
        fiat_deadline: u64,
        state: EscrowState,
        sequential: bool,
        sequential_escrow_address: Option<address>,
        fiat_paid: bool,
        counter: u64,
        funds: Option<Coin<USDC>>
    }

    // === EVENTS ===
    // Events as specified in section 6
    public struct EscrowCreated has copy, drop {
        object_id: ID,
        escrow_id: u64,
        trade_id: u64,
        seller: address,
        buyer: address,
        arbitrator: address,
        amount: u64,
        deposit_deadline: u64,
        fiat_deadline: u64,
        sequential: bool,
        sequential_escrow_address: Option<address>,
        timestamp: u64
    }

    public struct FundsDeposited has copy, drop {
        object_id: ID,
        escrow_id: u64,
        trade_id: u64,
        amount: u64,
        counter: u64,
        timestamp: u64
    }

    public struct FiatMarkedPaid has copy, drop {
        object_id: ID,
        escrow_id: u64,
        trade_id: u64,
        timestamp: u64
    }

    public struct EscrowReleased has copy, drop {
        object_id: ID,
        escrow_id: u64,
        trade_id: u64,
        buyer: address,
        amount: u64,
        counter: u64,
        timestamp: u64,
        destination: String // "direct to buyer" or "sequential escrow"
        // once past MVP, use codes
        // destination_type: u8 // 0 = direct to buyer, 1 = sequential escrow
    }

    public struct EscrowCancelled has copy, drop {
        object_id: ID,
        escrow_id: u64,
        trade_id: u64,
        seller: address,
        amount: u64,
        counter: u64,
        timestamp: u64
    }

    public struct DisputeOpened has copy, drop {
        object_id: ID,
        escrow_id: u64,
        trade_id: u64,
        disputing_party: address,
        timestamp: u64
    }

    public struct DisputeResolved has copy, drop {
        object_id: ID,
        escrow_id: u64,
        trade_id: u64,
        decision: bool, // true = release to buyer, false = return to seller
        counter: u64,
        timestamp: u64
    }

    // === METHOD ALIASES ===
    // === PUBLIC FUNCTIONS ===

    /// Create a new escrow as specified in section 4.A
    /// 
    /// This function initializes a new escrow with the provided parameters.
    /// The seller must be the caller, and the amount must be <= 100 USDC.
    /// For sequential trades, the sequential_escrow_address must be provided.
    /// TODO: make arbitrator a param?
    /// TODO: enable deposit_deadline, fiat_deadline as params with some validation to avoid extremes or impossible times
    public entry fun create_escrow(
        seller: address,
        buyer: address,
        amount: u64,
        escrow_id: u64, // sequential identifier for database tracking
        trade_id: u64,
        sequential: bool,
        sequential_escrow_address: Option<address>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Validate caller is seller (section 4.A preconditions)
        assert!(tx_context::sender(ctx) == seller, E102);
        
        // Validate amount (section 4.A preconditions)
        assert!(amount > 0, E100);
        assert!(amount <= MAX_AMOUNT, E101);
        
        // Validate sequential escrow address if sequential is true (section 4.A preconditions)
        if (sequential) {
            assert!(option::is_some(&sequential_escrow_address), E106);
        };
        
        // Calculate deadlines (section 1 requirements)
        let current_time = clock::timestamp_ms(clock);
        let deposit_deadline = current_time + (DEPOSIT_DEADLINE_MINUTES * 60 * 1000);
        // irrelevant placeholder value as this is set after escrow is funded
        let fiat_deadline = deposit_deadline + (FIAT_DEADLINE_MINUTES * 60 * 1000);
        
        // Create new escrow ID
        let id = object::new(ctx); // globally unique UID with metadata
        let object_id = object::uid_to_inner(&id); // inner id only, 32-byte value
        
        // Create escrow object as defined in section 3
        let escrow = Escrow {
            id,
            escrow_id,
            trade_id,
            seller,
            buyer,
            arbitrator: ARBITRATOR_ADDRESS, // Fixed arbitrator from constants
            amount,
            deposit_deadline,
            fiat_deadline,
            state: EscrowState::Created,
            sequential,
            sequential_escrow_address,
            fiat_paid: false,
            counter: 0,
            funds: option::none()
        };

        // Emit creation event as specified in section 6
        event::emit(EscrowCreated {
            object_id,
            escrow_id,
            trade_id,
            seller,
            buyer,
            arbitrator: ARBITRATOR_ADDRESS,
            amount,
            deposit_deadline,
            fiat_deadline,
            sequential,
            sequential_escrow_address,
            timestamp: current_time
        });

        // Share escrow object (making it accessible to all parties)
        transfer::share_object(escrow);
    }

    /// Fund the escrow with USDC as specified in section 4.B
    /// 
    /// This function allows the seller to fund the escrow with the agreed amount.
    /// It must be called before the deposit deadline expires.
    public entry fun fund_escrow(
        escrow: &mut Escrow,
        coin: Coin<USDC>,
        clock: &Clock,
        ctx: &mut TxContext // has to be mut as tx state will change
    ) {
        // Validate caller is seller (section 4.B preconditions)
        assert!(tx_context::sender(ctx) == escrow.seller, E102);
        
        // Validate escrow state (section 4.B preconditions)
        assert!(escrow.state == EscrowState::Created, E105);
        
        // Check deposit deadline (section 4.B preconditions)
        let current_time = clock::timestamp_ms(clock);
        assert!(current_time <= escrow.deposit_deadline, E103);
        
        // Validate amount matches exactly (section 4.B preconditions)
        assert!(coin::value(&coin) == escrow.amount, E100);
        
        // Ensure no funds are already present (safe approach)
        assert!(option::is_none(&escrow.funds), E105);
        
        // We need to modify individual fields to avoid the drop ability issue
        let counter_copy = escrow.counter;
        
        // Use option::fill instead of direct assignment
        option::fill(&mut escrow.funds, coin);
        
        // Modify primitive fields which have drop ability
        escrow.state = EscrowState::Funded;
        escrow.counter = counter_copy + 1;
        escrow.fiat_deadline = current_time + (FIAT_DEADLINE_MINUTES * 60 * 1000);
        
        // Emit event (section 6)
        event::emit(FundsDeposited {
            object_id: object::uid_to_inner(&escrow.id),
            escrow_id: escrow.escrow_id,
            trade_id: escrow.trade_id,
            amount: escrow.amount,
            counter: escrow.counter,
            timestamp: current_time
        });
    }

    /// Mark fiat as paid by the buyer as specified in section 4.C
    /// 
    /// This function allows the buyer to confirm they've sent the fiat payment.
    /// Once fiat is marked as paid, the seller cannot cancel the escrow.
    public entry fun mark_fiat_paid(
        escrow: &mut Escrow,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Validate caller is buyer (section 4.C preconditions)
        assert!(tx_context::sender(ctx) == escrow.buyer, E102);
        
        // Validate escrow state (section 4.C preconditions)
        assert!(escrow.state == EscrowState::Funded, E105);
        
        // Check fiat deadline (section 4.C preconditions)
        let current_time = clock::timestamp_ms(clock);
        assert!(current_time <= escrow.fiat_deadline, E104);
        
        // Update state (section 4.C postconditions)
        escrow.fiat_paid = true;
        
        // Emit event (section 6)
        event::emit(FiatMarkedPaid {
            object_id: object::uid_to_inner(&escrow.id),
            escrow_id: escrow.escrow_id,
            trade_id: escrow.trade_id,
            timestamp: current_time
        });
    }

    /// Update sequential escrow address
    /// 
    /// Allows the buyer to provide or update the sequential escrow address
    /// for sequential trades before release.
    public entry fun update_sequential_address(
    escrow: &mut Escrow,
    new_address: address,
    ctx: &mut TxContext
) {
    // Validate caller is buyer
    assert!(tx_context::sender(ctx) == escrow.buyer, E102);
    
    // Validate escrow is sequential - add clear error message
    assert!(escrow.sequential == true, E106); // Changed from E105 to E106 (Missing sequential escrow address)
    
    // Validate escrow is not in a terminal state
    assert!(
        escrow.state != EscrowState::Released && 
        escrow.state != EscrowState::Cancelled && 
        escrow.state != EscrowState::Resolved,
        E107
    );
    
    // Update address
    escrow.sequential_escrow_address = option::some(new_address);
    }

    /// Release escrow funds as specified in section 4.D
    /// 
    /// This function releases funds either to the buyer (standard escrow)
    /// or to the pre-defined sequential escrow account (sequential escrow).
    /// It can be called by the seller or arbitrator if fiat is marked as paid.
    public entry fun release_escrow(
        escrow: &mut Escrow,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Validate caller is seller or arbitrator (section 4.D preconditions)
        let sender = tx_context::sender(ctx);
        assert!(sender == escrow.seller || sender == escrow.arbitrator, E102);
        
        // Validate escrow state and fiat payment (section 4.D preconditions)
        assert!(escrow.state == EscrowState::Funded, E105);
        assert!(escrow.fiat_paid == true, E105);
        
        // For sequential trades, verify sequential_escrow_address exists (section 4.D preconditions)
        if (escrow.sequential) {
            assert!(option::is_some(&escrow.sequential_escrow_address), E106);
        };

        let funds = option::extract(&mut escrow.funds);
        let current_time = clock::timestamp_ms(clock);
        escrow.counter = escrow.counter + 1;
        
        // Handle fund transfer based on sequential flag (section 4.D postconditions)
        if (escrow.sequential) {
            // For sequential trades, transfer to the pre-defined sequential escrow
            let seq_address = option::extract(&mut escrow.sequential_escrow_address);
            transfer::public_transfer(funds, seq_address);

            // For sequential escrows
            // post-MVP replace with u8 and simple codes
            let destination_string = string::utf8(b"sequential escrow for trade");

            event::emit(EscrowReleased {
                object_id: object::uid_to_inner(&escrow.id),
                escrow_id: escrow.escrow_id,
                trade_id: escrow.trade_id,
                buyer: escrow.buyer,
                amount: escrow.amount,
                counter: escrow.counter,
                timestamp: current_time,
                destination: destination_string
            });

        } else {
            // For standard trades, transfer directly to buyer
            transfer::public_transfer(funds, escrow.buyer);

            event::emit(EscrowReleased {
                object_id: object::uid_to_inner(&escrow.id),
                escrow_id: escrow.escrow_id,
                trade_id: escrow.trade_id,
                buyer: escrow.buyer,
                amount: escrow.amount,
                counter: escrow.counter,
                timestamp: current_time,
                destination: string::utf8(b"direct to buyer")
            });
        };
        
        escrow.state = EscrowState::Released;
    }

    /// Cancel escrow as specified in section 4.E
    /// 
    /// This function allows the seller or arbitrator to cancel the escrow
    /// and return funds to the seller. Cannot be called if fiat is marked as paid.
    public entry fun cancel_escrow(
        escrow: &mut Escrow,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        let current_time = clock::timestamp_ms(clock);
        
        // Validate caller and conditions (section 4.E preconditions)
        assert!(
            sender == escrow.seller || 
            sender == escrow.arbitrator, 
            E102
        );
        
        // Cannot cancel if fiat is marked as paid (section 4.E preconditions)
        assert!(!escrow.fiat_paid, E105);
        
        // Validate state (section 4.E preconditions)
        assert!(
            escrow.state == EscrowState::Created || 
            escrow.state == EscrowState::Funded, 
            E105
        );
        
        // If funded, return funds to seller (section 4.E postconditions)
        if (option::is_some(&escrow.funds)) {
            let funds = option::extract(&mut escrow.funds);
            transfer::public_transfer(funds, escrow.seller);
        };
        
        escrow.state = EscrowState::Cancelled;
        escrow.counter = escrow.counter + 1;
        
        // Emit cancellation event (section 6)
        event::emit(EscrowCancelled {
            object_id: object::uid_to_inner(&escrow.id),
            escrow_id: escrow.escrow_id,
            trade_id: escrow.trade_id,
            seller: escrow.seller,
            amount: escrow.amount,
            counter: escrow.counter,
            timestamp: current_time
        });
    }

    /// Open a dispute as specified in section 4.F.1
    /// 
    /// Allows the buyer or seller to open a dispute if fiat has been marked as paid.
    /// TODO: improve dispute process to add
    /// - deterrent for frivolous disputes
    /// - structured way for both parties to present evidence
    /// - resolution timeframe
    /// - accountability for pattern abusers.
    public entry fun open_dispute(
        escrow: &mut Escrow,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        
        // Validate caller is buyer or seller (section 4.F.1 preconditions)
        assert!(
            sender == escrow.buyer || 
            sender == escrow.seller, 
            E102
        );
        
        // Validate escrow state and fiat payment status (section 4.F.1 preconditions)
        assert!(escrow.state == EscrowState::Funded, E105);
        assert!(escrow.fiat_paid == true, E105);
        
        // Update state to disputed (section 4.F.1 postconditions)
        escrow.state = EscrowState::Disputed;
        
        // Emit dispute event (section 6)
        event::emit(DisputeOpened {
            object_id: object::uid_to_inner(&escrow.id),
            escrow_id: escrow.escrow_id,
            trade_id: escrow.trade_id,
            disputing_party: sender,
            timestamp: clock::timestamp_ms(clock)
        });
    }

    /// Resolve a dispute as specified in section 4.F.2
    /// 
    /// Allows the arbitrator to resolve a dispute by releasing funds
    /// to either the buyer or seller.
    public entry fun resolve_dispute(
        escrow: &mut Escrow,
        decision: bool, // true = release to buyer, false = return to seller
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Validate caller is arbitrator (section 4.F.2 preconditions)
        assert!(tx_context::sender(ctx) == escrow.arbitrator, E102);
        
        // Validate escrow is in disputed state (section 4.F.2 preconditions)
        assert!(escrow.state == EscrowState::Disputed, E105);
        
        // Ensure funds are present
        assert!(option::is_some(&escrow.funds), E105);
        
        let current_time = clock::timestamp_ms(clock);
        let counter_copy = escrow.counter;
        
        // Extract funds for transfer based on arbitrator decision
        let funds = option::extract(&mut escrow.funds);
        
        if (decision) {
            // Release funds based on sequential flag (section 4.F.2 postconditions)
            if (escrow.sequential) {
                assert!(option::is_some(&escrow.sequential_escrow_address), E106);
                let seq_address = option::extract(&mut escrow.sequential_escrow_address);
                transfer::public_transfer(funds, seq_address);
            } else {
                transfer::public_transfer(funds, escrow.buyer);
            };
        } else {
            // Return funds to seller (section 4.F.2 postconditions)
            transfer::public_transfer(funds, escrow.seller);
        };
        
        escrow.state = EscrowState::Resolved;
        escrow.counter = counter_copy + 1;
        
        // Emit dispute resolution event (section 6)
        event::emit(DisputeResolved {
            object_id: object::uid_to_inner(&escrow.id),
            escrow_id: escrow.escrow_id,
            trade_id: escrow.trade_id,
            decision,
            counter: escrow.counter,
            timestamp: current_time
        });
    }

    /// Auto-cancel escrow on deadline expiry as specified in section 4.F.3
    /// 
    /// Allows the arbitrator to automatically cancel an escrow if
    /// either deadline has expired and the trade is not in a terminal state.
    public entry fun auto_cancel(
        escrow: &mut Escrow,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Validate caller is arbitrator (section 4.F.3 preconditions)
        assert!(tx_context::sender(ctx) == escrow.arbitrator, E102);

        let current_time = clock::timestamp_ms(clock);
        
        // Check which deadline has expired with specific error codes
        if (escrow.state == EscrowState::Created) {
            // For created but unfunded escrows, check deposit deadline
            assert!(current_time > escrow.deposit_deadline, E103); // Deposit deadline error
        } else {
            // For funded escrows, check fiat deadline
            assert!(current_time > escrow.fiat_deadline && !escrow.fiat_paid, E104); // Fiat deadline error
        };
        
        
        // Validate escrow is not in terminal state (section 4.F.3 preconditions)
        assert!(
            escrow.state != EscrowState::Released && 
            escrow.state != EscrowState::Cancelled && 
            escrow.state != EscrowState::Resolved,
            E107
        );
        
        // Return funds if present (section 4.F.3 postconditions)
        if (option::is_some(&escrow.funds)) {
            let funds = option::extract(&mut escrow.funds);
            transfer::public_transfer(funds, escrow.seller);
        };
        
        escrow.state = EscrowState::Cancelled;
        escrow.counter = escrow.counter + 1;
        
        // Emit auto-cancellation event (section 6)
        event::emit(EscrowCancelled {
            object_id: object::uid_to_inner(&escrow.id),
            escrow_id: escrow.escrow_id,
            trade_id: escrow.trade_id,
            seller: escrow.seller,
            amount: escrow.amount,
            counter: escrow.counter,
            timestamp: current_time
        });
    }

    // === VIEW FUNCTIONS ===

    /// Get escrow details
    /// 
    /// View function to retrieve basic escrow information.
    public fun get_escrow_details(escrow: &Escrow): (
        u64,    // escrow_id
        u64,    // trade_id
        address, // seller
        address, // buyer
        u64,    // amount
        u64,    // deposit_deadline
        u64,    // fiat_deadline
        bool,   // sequential
        bool    // fiat_paid
    ) {
        (
            escrow.escrow_id,
            escrow.trade_id,
            escrow.seller,
            escrow.buyer,
            escrow.amount,
            escrow.deposit_deadline,
            escrow.fiat_deadline,
            escrow.sequential,
            escrow.fiat_paid
        )
    }

    /// Get escrow state
    /// 
    /// View function to check the current state of the escrow.
    public fun get_escrow_state(escrow: &Escrow): EscrowState {
        escrow.state
    }

    /// Check if escrow is in active state
    /// 
    /// Returns true if escrow is not in a terminal state.
    public fun is_active(escrow: &Escrow): bool {
        escrow.state != EscrowState::Released &&
        escrow.state != EscrowState::Cancelled &&
        escrow.state != EscrowState::Resolved
    }

    /// Check if sequential escrow address is set
    public fun has_sequential_address(escrow: &Escrow): bool {
        escrow.sequential && option::is_some(&escrow.sequential_escrow_address)
    }
    
    // === Admin Functions ===
    // === Package Functions ===
    // === Private Functions ===

    // === TEST FUNCTIONS ===
    #[test_only]
    public fun setup_test_escrow(
        seller: address,
        buyer: address,
        amount: u64,
        sequential: bool,
        ctx: &mut TxContext
    ): Escrow {
        Escrow {
            id: object::new(ctx),
            escrow_id: 1000,
            trade_id: 1000,
            seller,
            buyer,
            arbitrator: ARBITRATOR_ADDRESS,
            amount,
            deposit_deadline: 0,
            fiat_deadline: 0,
            state: EscrowState::Created,
            sequential,
            sequential_escrow_address: option::none(),
            fiat_paid: false,
            counter: 0,
            funds: option::none()
        }
    }
}
