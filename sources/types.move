module multi_sig_treasury::types {
    use std::string::String;
    use std::vector;
    use sui::object::{Self, ID, UID};
    use sui::balance::{Self, Balance};
    use sui::table::{Self, Table};
    use sui::tx_context::TxContext;
    use sui::transfer;
    use sui::coin::{Self, Coin};
    use sui::clock::Clock;

    struct Treasury<phantom T> has key {
        id: UID,
        name: String,
        signers: vector<address>,
        threshold: u64,
        balance: Balance<T>,
        total_spent: u64,
        proposal_count: u64,
        is_frozen: bool,
        emergency_signers: vector<address>,
        emergency_threshold: u64,
    }

    struct Proposal has key {
        id: UID,
        treasury_id: ID,
        creator: address,
        category: String,
        amount: u64,
        recipient: address,
        signatures: Table<address, bool>,
        status: u8,
        time_locked_until: u64,
        description: String,
    }

    struct SpendingLimitPolicy has store , drop {
        category: String,
        daily_limit: u64,
        weekly_limit: u64,
        monthly_limit: u64,
        per_transaction_cap: u64,
    }

    struct WhitelistPolicy has store , drop{
        whitelist: vector<address>,
        is_enabled: bool,
    }

    struct SpendingTracker has store {
        category: String,
        daily_spent: u64,
        weekly_spent: u64,
        monthly_spent: u64,
        last_reset_day: u64,
        last_reset_week: u64,
        last_reset_month: u64,
    }

    struct PolicyManager has key {
        id: UID,
        treasury_id: ID,
        spending_policies: Table<String, SpendingLimitPolicy>,
        whitelist_policies: Table<String, WhitelistPolicy>,
        spending_trackers: Table<String, SpendingTracker>,
    }

    struct EmergencyModule has key {
        id: UID,
        treasury_id: ID,
        emergency_signers: vector<address>,
        super_majority_threshold: u64,
        cooldown_period: u64,
        last_emergency_time: u64,
    }

    struct TreasuryCreated has copy, drop {
        treasury_id: ID,
        creator: address,
        threshold: u64,
    }

    struct ProposalCreated has copy, drop {
        proposal_id: ID,
        amount: u64,
    }

    struct ProposalExecuted has copy, drop {
        proposal_id: ID,
        amount: u64,
    }

    struct ProposalSigned has copy, drop {
        proposal_id: ID,
        signer: address,
        signature_count: u64,
    }

    struct EmergencyWithdrawal has copy, drop {
        treasury_id: ID,
        amount: u64,
    }

    struct TreasuryFrozen has copy, drop {
        treasury_id: ID,
    }

    const E_NOT_AUTHORIZED: u64 = 1;
    const E_INSUFFICIENT_SIGNATURES: u64 = 2;
    const E_TIME_LOCK_ACTIVE: u64 = 3;
    const E_INVALID_AMOUNT: u64 = 4;
    const E_FROZEN: u64 = 5;
    const E_INVALID_THRESHOLD: u64 = 6;
    const E_DUPLICATE_SIGNATURE: u64 = 7;
    const E_SPENDING_LIMIT_EXCEEDED: u64 = 8;
    const E_NOT_WHITELISTED: u64 = 9;
    const E_COOLDOWN_ACTIVE: u64 = 10;

    const STATUS_PENDING: u8 = 0;
    const STATUS_EXECUTED: u8 = 1;
    const STATUS_CANCELLED: u8 = 2;

    const DAY_MS: u64 = 86400000;
    const WEEK_MS: u64 = 604800000;
    const MONTH_MS: u64 = 2592000000;

    public fun create_treasury<T>(
        name: String,
        signers: vector<address>,
        threshold: u64,
        emergency_signers: vector<address>,
        ctx: &mut TxContext,
    ): ID {
        let len = vector::length(&signers);
        assert!(len > 0 && threshold > 0 && threshold <= len, E_INVALID_THRESHOLD);

        let treasury = Treasury<T> {
            id: object::new(ctx),
            name,
            signers,
            threshold,
            balance: balance::zero(),
            total_spent: 0,
            proposal_count: 0,
            is_frozen: false,
            emergency_signers,
            emergency_threshold: ((len * 3) / 4) + 1,
        };

        let id = object::uid_to_inner(&treasury.id);
        sui::event::emit(TreasuryCreated {
            treasury_id: id,
            creator: sui::tx_context::sender(ctx),
            threshold,
        });
        transfer::share_object(treasury);
        id
    }

    public fun deposit<T>(
        treasury: &mut Treasury<T>,
        coin: Coin<T>,
        _ctx: &mut TxContext,
    ) {
        assert!(!treasury.is_frozen, E_FROZEN);
        let amt = coin::value(&coin);
        assert!(amt > 0, E_INVALID_AMOUNT);
        balance::join(&mut treasury.balance, coin::into_balance(coin));
    }

    public fun freeze_treasury<T>(
        treasury: &mut Treasury<T>,
        ctx: &mut TxContext,
    ) {
        let sender = sui::tx_context::sender(ctx);
        assert!(vector::contains(&treasury.emergency_signers, &sender), E_NOT_AUTHORIZED);
        treasury.is_frozen = true;
        sui::event::emit(TreasuryFrozen {
            treasury_id: object::uid_to_inner(&treasury.id),
        });
    }

    public fun unfreeze_treasury<T>(
        treasury: &mut Treasury<T>,
        ctx: &mut TxContext,
    ) {
        let sender = sui::tx_context::sender(ctx);
        assert!(vector::contains(&treasury.signers, &sender), E_NOT_AUTHORIZED);
        treasury.is_frozen = false;
    }

    public fun create_proposal(
        treasury_id: ID,
        category: String,
        recipient: address,
        amount: u64,
        time_lock: u64,
        description: String,
        clock: &Clock,
        ctx: &mut TxContext,
    ): ID {
        assert!(amount > 0, E_INVALID_AMOUNT);
        let creator = sui::tx_context::sender(ctx);

        let proposal = Proposal {
            id: object::new(ctx),
            treasury_id,
            creator,
            category,
            amount,
            recipient,
            signatures: table::new(ctx),
            status: STATUS_PENDING,
            time_locked_until: sui::clock::timestamp_ms(clock) + time_lock,
            description,
        };

        let pid = object::uid_to_inner(&proposal.id);
        sui::event::emit(ProposalCreated {
            proposal_id: pid,
            amount,
        });
        transfer::share_object(proposal);
        pid
    }

    public fun sign_proposal<T>(
        treasury: &Treasury<T>,
        proposal: &mut Proposal,
        ctx: &mut TxContext,
    ) {
        let signer = sui::tx_context::sender(ctx);
        assert!(vector::contains(&treasury.signers, &signer), E_NOT_AUTHORIZED);
        assert!(proposal.status == STATUS_PENDING, E_NOT_AUTHORIZED);
        assert!(!table::contains(&proposal.signatures, signer), E_DUPLICATE_SIGNATURE);
        table::add(&mut proposal.signatures, signer, true);
        
        sui::event::emit(ProposalSigned {
            proposal_id: object::uid_to_inner(&proposal.id),
            signer,
            signature_count: table::length(&proposal.signatures),
        });
    }

    public fun execute_proposal<T>(
        treasury: &mut Treasury<T>,
        proposal: &mut Proposal,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<T> {
        assert!(proposal.status == STATUS_PENDING, E_NOT_AUTHORIZED);
        assert!(!treasury.is_frozen, E_FROZEN);
        assert!(sui::clock::timestamp_ms(clock) >= proposal.time_locked_until, E_TIME_LOCK_ACTIVE);
        assert!(table::length(&proposal.signatures) >= treasury.threshold, E_INSUFFICIENT_SIGNATURES);

        proposal.status = STATUS_EXECUTED;
        treasury.total_spent = treasury.total_spent + proposal.amount;

        sui::event::emit(ProposalExecuted {
            proposal_id: object::uid_to_inner(&proposal.id),
            amount: proposal.amount,
        });

        coin::take(&mut treasury.balance, proposal.amount, ctx)
    }

    public fun cancel_proposal(
        proposal: &mut Proposal,
        ctx: &mut TxContext,
    ) {
        assert!(sui::tx_context::sender(ctx) == proposal.creator, E_NOT_AUTHORIZED);
        assert!(proposal.status == STATUS_PENDING, E_NOT_AUTHORIZED);
        proposal.status = STATUS_CANCELLED;
    }

    public fun create_policy_manager(
        treasury_id: ID,
        ctx: &mut TxContext,
    ): ID {
        let manager = PolicyManager {
            id: object::new(ctx),
            treasury_id,
            spending_policies: table::new(ctx),
            whitelist_policies: table::new(ctx),
            spending_trackers: table::new(ctx),
        };
        
        let id = object::uid_to_inner(&manager.id);
        transfer::share_object(manager);
        id
    }

    public fun add_spending_limit(
        policy_manager: &mut PolicyManager,
        category: String,
        daily_limit: u64,
        weekly_limit: u64,
        monthly_limit: u64,
        per_transaction_cap: u64,
        _ctx: &mut TxContext,
    ) {
        let policy = SpendingLimitPolicy {
            category,
            daily_limit,
            weekly_limit,
            monthly_limit,
            per_transaction_cap,
        };
        
        if (table::contains(&policy_manager.spending_policies, category)) {
            table::remove(&mut policy_manager.spending_policies, category);
        };
        table::add(&mut policy_manager.spending_policies, category, policy);
    }

    public fun add_whitelist(
        policy_manager: &mut PolicyManager,
        category: String,
        whitelist: vector<address>,
        _ctx: &mut TxContext,
    ) {
        let policy = WhitelistPolicy {
            whitelist,
            is_enabled: true,
        };
        
        if (table::contains(&policy_manager.whitelist_policies, category)) {
            table::remove(&mut policy_manager.whitelist_policies, category);
        };
        table::add(&mut policy_manager.whitelist_policies, category, policy);
    }

    public fun create_emergency_module(
        treasury_id: ID,
        emergency_signers: vector<address>,
        cooldown_period: u64,
        ctx: &mut TxContext,
    ): ID {
        let signer_count = vector::length(&emergency_signers);
        let em = EmergencyModule {
            id: object::new(ctx),
            treasury_id,
            emergency_signers,
            super_majority_threshold: ((signer_count * 3) / 4) + 1,
            cooldown_period,
            last_emergency_time: 0,
        };

        let id = object::uid_to_inner(&em.id);
        transfer::share_object(em);
        id
    }

    public fun emergency_withdraw<T>(
        treasury: &mut Treasury<T>,
        emergency_module: &mut EmergencyModule,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<T> {
        let sender = sui::tx_context::sender(ctx);
        let timestamp = sui::clock::timestamp_ms(clock);
        
        assert!(vector::contains(&emergency_module.emergency_signers, &sender), E_NOT_AUTHORIZED);
        assert!(timestamp - emergency_module.last_emergency_time >= emergency_module.cooldown_period, E_COOLDOWN_ACTIVE);

        emergency_module.last_emergency_time = timestamp;
        treasury.total_spent = treasury.total_spent + amount;

        sui::event::emit(EmergencyWithdrawal {
            treasury_id: object::uid_to_inner(&treasury.id),
            amount,
        });

        coin::take(&mut treasury.balance, amount, ctx)
    }

    public fun treasury_balance<T>(t: &Treasury<T>): u64 { balance::value(&t.balance) }
    public fun treasury_threshold<T>(t: &Treasury<T>): u64 { t.threshold }
    public fun treasury_signers<T>(t: &Treasury<T>): vector<address> { t.signers }
    public fun is_signer<T>(t: &Treasury<T>, addr: address): bool { vector::contains(&t.signers, &addr) }
    public fun proposal_status(p: &Proposal): u8 { p.status }
    public fun proposal_amount(p: &Proposal): u64 { p.amount }
    public fun proposal_signatures(p: &Proposal): u64 { table::length(&p.signatures) }
    public fun status_pending(): u8 { STATUS_PENDING }
    public fun status_executed(): u8 { STATUS_EXECUTED }
    public fun treasury_is_frozen<T>(t: &Treasury<T>): bool { t.is_frozen }
}
