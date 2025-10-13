#[allow(unused_mut_parameter, lint(coin_field))]

module airdrop::public_airdrops;
    use sui::coin::{Self, Coin};
    use sui::clock::{Self, Clock};
    use sui::table::{Self, Table};
    use sui::hash;
    use sui::address;
    use sui::bcs;
    use sui::event;
    use std::string::{Self, String};

    // ===== Constants =====
    const CONTRACT_OWNER: address = @owner;
    const DEFAULT_EXPIRY_HOURS: u64 = 48; // 48 hours default
    const MILLISECONDS_PER_HOUR: u64 = 3600000;
    
    // Distribution Types
    const DISTRIBUTION_TYPE_EQUAL: u8 = 0;
    const DISTRIBUTION_TYPE_RANDOM: u8 = 1;
    
    // Claim Restriction Types
    const CLAIM_RESTRICTION_ADDRESS: u8 = 0; // One claim per address
    const CLAIM_RESTRICTION_DEVICE: u8 = 1;  // One claim per device (address + device fingerprint)
    
    // Error codes
    #[error]
    const E_INVALID_RECEIVER_LIMIT: vector<u8> = b"Invalid receiver limit, must be between 1 and 100000";
    #[error]
    const E_INSUFFICIENT_AMOUNT: vector<u8> = b"Insufficient amount provided for droplet";
    #[error]
    const E_ALREADY_CLAIMED: vector<u8> = b"You have already claimed from this droplet";
    #[error]
    const E_DEVICE_ALREADY_CLAIMED: vector<u8> = b"This device has already claimed from this droplet";
    #[error]
    const E_DROPLET_EXPIRED: vector<u8> = b"This droplet has expired";
    #[error]
    const E_DROPLET_CLOSED: vector<u8> = b"This droplet is closed";
    #[error]
    const E_RECEIVER_LIMIT_REACHED: vector<u8> = b"Receiver limit reached for this droplet";
    #[error]
    const E_INSUFFICIENT_BALANCE: vector<u8> = b"Insufficient balance in droplet to claim";
    #[error]
    const E_DROPLET_NOT_FOUND: vector<u8> = b"Droplet ID not found";
    #[error]
    const E_INVALID_FEE_PERCENTAGE: vector<u8> = b"Invalid fee percentage, must be between 0 and 1000 (10%)";
    #[error]
    const E_INVALID_DROPLET_ID: vector<u8> = b"Invalid droplet ID, must be exactly 6 characters";
    #[error]
    const E_INVALID_NAME_LENGTH: vector<u8> = b"Name must be between 2 and 20 characters";
    #[error]
    const E_NAME_ALREADY_TAKEN: vector<u8> = b"This name is already taken";
    #[error]
    const E_INVALID_DISTRIBUTION_TYPE: vector<u8> = b"Invalid distribution type";
    #[error]
    const E_NOT_CREATOR: vector<u8> = b"Only the creator can delete this airdrop";
    #[error]
    const E_CANNOT_DELETE_CLAIMED: vector<u8> = b"Cannot delete airdrop after claims have been made";
    #[error]
    const E_INVALID_CLAIM_RESTRICTION: vector<u8> = b"Invalid claim restriction type";
    #[error]
    const E_INVALID_DEVICE_FINGERPRINT: vector<u8> = b"Invalid device fingerprint";
    #[error]
    const E_INSUFFICIENT_TOTAL_FOR_DISTINCT: vector<u8> = b"Insufficient total amount to guarantee distinct random shares";

    public struct DropletRegistry has key {
        id: UID,
        droplets: Table<String, address>, 
        fee_percentage: u64, 
        total_droplets_created: u64,
        total_fees_collected: Table<String, u64>,
        user_created_droplets: Table<address, vector<String>>, 
        user_claimed_droplets: Table<address, vector<String>>,
        user_names: Table<address, String>,
        name_to_address: Table<String, address>,
    }

    public struct Droplet<phantom CoinType> has key, store {
        id: UID,
        droplet_id: String,
        sender: address,
        total_amount: u64,
        claimed_amount: u64,
        receiver_limit: u64,
        num_claimed: u64,
        created_at: u64,
        expiry_time: u64, 
        claimed: Table<address, String>, // address -> claimer name
        device_claims: Table<String, bool>, // device_fingerprint -> claimed
        claimers_list: vector<address>, 
        claimer_names: vector<String>, 
        coin: Coin<CoinType>,
        is_closed: bool,
        message: String,
        distribution_type: u8, // 0 = equal, 1 = random
        claim_restriction: u8, // 0 = address only, 1 = address + device
        random_shares: Table<u64, u64>, // claim_index -> amount (for random distribution)
    }

    public struct AdminCap has key {
        id: UID,
    }

    public struct DropletInfo has copy, drop {
        droplet_id: String,
        sender: address,
        total_amount: u64,
        claimed_amount: u64,
        remaining_amount: u64,
        receiver_limit: u64,
        num_claimed: u64,
        created_at: u64,
        expiry_time: u64,
        is_expired: bool,
        is_closed: bool,
        message: String,
        claimers: vector<address>,
        claimer_names: vector<String>,
        distribution_type: u8,
        claim_restriction: u8,
    }

    public struct UserNameRegistered has copy, drop {
        user: address,
        old_name: Option<String>,
        new_name: String,
        timestamp: u64,
    }

    public struct DropletCreated has copy, drop { 
        droplet_id: String,
        droplet_object_id: address, 
        sender: address,
        total_amount: u64,
        fee_amount: u64,
        net_amount: u64,
        receiver_limit: u64,
        expiry_hours: u64,
        message: String,
        amount_per_receiver: u64,
        created_at: u64,
        expiry_time: u64,
        distribution_type: u8,
        claim_restriction: u8,
    }

    public struct DropletClaimed has copy, drop {
        droplet_id: String,
        claimer: address,
        claimer_name: String,
        claim_amount: u64,
        message: String,
        claimed_at: u64,
        device_fingerprint: Option<String>,
    }

    public struct DropletClosed has copy, drop {
        droplet_id: String,
        sender: address,
        refund_amount: u64,
        total_claimed: u64,
        num_claimers: u64,
        reason: String,
        closed_at: u64,
        remaining_amount: u64,
    }

    public struct AirdropDeleted has copy, drop {
        droplet_id: String,
        sender: address,
        refund_amount: u64,
        deleted_at: u64,
    }

    public struct FeePercentageUpdated has copy, drop {
        old_fee: u64,
        new_fee: u64,
        updated_by: address,
        timestamp: u64,
    }

    public struct FeeCollected has copy, drop {
        droplet_id: String,
        token_type: String,
        fee_amount: u64,
        recipient: address,
        timestamp: u64,
    }

    fun init(ctx: &mut TxContext) {
        let admin_cap = AdminCap {
            id: object::new(ctx),
        };
        sui::transfer::transfer(admin_cap, tx_context::sender(ctx));

        let registry = DropletRegistry {
            id: object::new(ctx),
            droplets: table::new(ctx),
            fee_percentage: 130, // 1.3% in basis points
            total_droplets_created: 0,
            total_fees_collected: table::new(ctx),
            user_created_droplets: table::new(ctx),
            user_claimed_droplets: table::new(ctx),
            user_names: table::new(ctx),
            name_to_address: table::new(ctx),
        };
        sui::transfer::share_object(registry);
    }

    entry fun register_name(
        registry: &mut DropletRegistry,
        name: String,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let user = tx_context::sender(ctx);
        let name_length = string::length(&name);
        
        assert!(name_length >= 2 && name_length <= 20, E_INVALID_NAME_LENGTH);
        
        if (table::contains(&registry.name_to_address, name)) {
            let existing_owner = *table::borrow(&registry.name_to_address, name);
            assert!(existing_owner == user, E_NAME_ALREADY_TAKEN);
        };

        let old_name = if (table::contains(&registry.user_names, user)) {
            let old = *table::borrow(&registry.user_names, user);
            table::remove(&mut registry.name_to_address, old);
            option::some(old)
        } else {
            option::none<String>()
        };

        if (table::contains(&registry.user_names, user)) {
            *table::borrow_mut(&mut registry.user_names, user) = name;
        } else {
            table::add(&mut registry.user_names, user, name);
        };

        table::add(&mut registry.name_to_address, name, user);

        event::emit(UserNameRegistered {
            user,
            old_name,
            new_name: name,
            timestamp: clock::timestamp_ms(clock),
        });
    }

    fun generate_droplet_id(sender: address, timestamp: u64, ctx: &mut TxContext): String {
        let mut data = vector::empty<u8>();
        vector::append(&mut data, address::to_bytes(sender));
        vector::append(&mut data, bcs::to_bytes(&timestamp));
        vector::append(&mut data, bcs::to_bytes(&tx_context::fresh_object_address(ctx)));
        
        let hash_bytes = hash::keccak256(&data);
        let mut id_chars = vector::empty<u8>();
        
        let charset = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ";
        let mut i = 0;
        while (i < 6 && i < vector::length(&hash_bytes)) {
            let byte_val = *vector::borrow(&hash_bytes, i);
            let char_index = (byte_val as u64) % 36;
            vector::push_back(&mut id_chars, *vector::borrow(&charset, char_index));
            i = i + 1;
        };
        
        string::utf8(id_chars)
    }

    #[allow(unused_type_parameter)]
    fun get_token_type<CoinType>(): String {
        string::utf8(b"COIN_TYPE")
    }

    fun calculate_claim_amount(remaining_amount: u64, remaining_receivers: u64): u64 {
        if (remaining_receivers == 0) {
            0
        } else {
            remaining_amount / remaining_receivers
        }
    }

    // Generate random weight for distribution
    fun generate_random_weight(
        sender: address,
        claimer_index: u64,
        created_at: u64,
        droplet_id: String
    ): u64 {
        let mut data = vector::empty<u8>();
        vector::append(&mut data, address::to_bytes(sender));
        vector::append(&mut data, bcs::to_bytes(&claimer_index));
        vector::append(&mut data, bcs::to_bytes(&created_at));
        
        // Manually copy string bytes
        let string_bytes = string::as_bytes(&droplet_id);
        let len = vector::length(string_bytes);
        let mut i = 0;
        while (i < len) {
            vector::push_back(&mut data, *vector::borrow(string_bytes, i));
            i = i + 1;
        };
        
        let hash_bytes = hash::keccak256(&data);
        
        if (vector::length(&hash_bytes) >= 8) {
            let mut weight: u64 = 0;
            let mut i = 0;
            while (i < 8) {
                let byte_val = *vector::borrow(&hash_bytes, i);
                weight = weight * 256 + (byte_val as u64);
                i = i + 1;
            };
            // Return weight between 1 and 10000 to avoid zeros
            (weight % 10000) + 1
        } else {
            5000 // Fallback to middle value
        }
    }

    // Pre-calculate random distribution using the improved algorithm
    fun precalculate_random_distribution<CoinType>(
        droplet: &mut Droplet<CoinType>,
        _ctx: &mut TxContext
    ) {
        let total_cents = droplet.total_amount;
        let num_receivers = droplet.receiver_limit;
        
        // Check feasibility: need at least x(x+1)/2 cents for distinct amounts
        let min_cents_needed = (num_receivers * (num_receivers + 1)) / 2;
        assert!(total_cents >= min_cents_needed, E_INSUFFICIENT_TOTAL_FOR_DISTINCT);
        
        // Step 1: Assign baseline (1, 2, 3, ..., x)
        let mut baseline_sum: u64 = 0;
        let mut i: u64 = 1;
        while (i <= num_receivers) {
            baseline_sum = baseline_sum + i;
            i = i + 1;
        };
        
        // Step 2: Calculate leftover to distribute
        let leftover = total_cents - baseline_sum;
        
        // Step 3: Generate random weights
        let mut weights = vector::empty<u64>();
        let mut weight_sum: u64 = 0;
        i = 0;
        while (i < num_receivers) {
            let weight = generate_random_weight(
                droplet.sender,
                i,
                droplet.created_at,
                droplet.droplet_id
            );
            vector::push_back(&mut weights, weight);
            weight_sum = weight_sum + weight;
            i = i + 1;
        };
        
        // Step 4 & 5: Allocate leftover proportionally using largest remainder method
        let mut floors = vector::empty<u64>();
        let mut fractions = vector::empty<u64>(); // Store as fixed-point (multiply by 10000)
        let mut floor_sum: u64 = 0;
        
        i = 0;
        while (i < num_receivers) {
            let weight = *vector::borrow(&weights, i);
            let proportional = (leftover * weight) / weight_sum;
            let floor_val = proportional;
            let fraction = ((leftover * weight * 10000) / weight_sum) % 10000;
            
            vector::push_back(&mut floors, floor_val);
            vector::push_back(&mut fractions, fraction);
            floor_sum = floor_sum + floor_val;
            i = i + 1;
        };
        
        let remainder = leftover - floor_sum;
        
        // Distribute remainder to indices with largest fractions
        let mut adjustments = vector::empty<u64>();
        i = 0;
        while (i < num_receivers) {
            vector::push_back(&mut adjustments, 0);
            i = i + 1;
        };
        
        let mut distributed: u64 = 0;
        while (distributed < remainder) {
            let mut max_fraction: u64 = 0;
            let mut max_index: u64 = 0;
            
            i = 0;
            while (i < num_receivers) {
                let frac = *vector::borrow(&fractions, i);
                let adj = *vector::borrow(&adjustments, i);
                if (adj == 0 && frac > max_fraction) {
                    max_fraction = frac;
                    max_index = i;
                };
                i = i + 1;
            };
            
            *vector::borrow_mut(&mut adjustments, max_index) = 1;
            distributed = distributed + 1;
        };
        
        // Step 6: Calculate final amounts
        i = 0;
        while (i < num_receivers) {
            let baseline = i + 1;
            let floor_val = *vector::borrow(&floors, i);
            let adjustment = *vector::borrow(&adjustments, i);
            let final_amount = baseline + floor_val + adjustment;
            
            table::add(&mut droplet.random_shares, i, final_amount);
            i = i + 1;
        };
    }

    fun update_user_history(
        registry: &mut DropletRegistry,
        user: address,
        droplet_id: String,
        is_created: bool,
        _ctx: &TxContext 
    ) {
        if (is_created) {
            if (!table::contains(&registry.user_created_droplets, user)) {
                table::add(&mut registry.user_created_droplets, user, vector::empty<String>());
            };
            let user_droplets = table::borrow_mut(&mut registry.user_created_droplets, user);
            vector::push_back(user_droplets, droplet_id);
        } else {
            if (!table::contains(&registry.user_claimed_droplets, user)) {
                table::add(&mut registry.user_claimed_droplets, user, vector::empty<String>());
            };
            let user_droplets = table::borrow_mut(&mut registry.user_claimed_droplets, user);
            vector::push_back(user_droplets, droplet_id);
        };
    }

    entry fun create_droplet<CoinType>(
        registry: &mut DropletRegistry,
        total_amount: u64,
        receiver_limit: u64,
        expiry_hours: Option<u64>,
        message: String,
        distribution_type: u8,
        claim_restriction: u8,
        mut coin: Coin<CoinType>,
        clock: &Clock,
        ctx: &mut TxContext 
    ) {
        // Validations
        assert!(receiver_limit > 0 && receiver_limit <= 100000, E_INVALID_RECEIVER_LIMIT);
        assert!(total_amount > 0, E_INSUFFICIENT_AMOUNT);
        assert!(distribution_type <= 1, E_INVALID_DISTRIBUTION_TYPE);
        assert!(claim_restriction <= 1, E_INVALID_CLAIM_RESTRICTION);

        let sender = tx_context::sender(ctx);
        let current_time = clock::timestamp_ms(clock);
        
        let hours = if (option::is_some(&expiry_hours)) {
            *option::borrow(&expiry_hours)
        } else {
            DEFAULT_EXPIRY_HOURS
        };
        let expiry_time = current_time + (hours * MILLISECONDS_PER_HOUR);

        // Calculate fee - fee is added on top of the amount to send
        let fee_amount = (total_amount * registry.fee_percentage) / 10000;
        let total_with_fee = total_amount + fee_amount;
        
        // Verify user provided enough coins (amount + fee)
        assert!(coin::value(&coin) >= total_with_fee, E_INSUFFICIENT_AMOUNT);

        // Split coin for fee and send to contract owner
        if (fee_amount > 0) {
            let fee_coin = coin::split(&mut coin, fee_amount, ctx);
            sui::transfer::public_transfer(fee_coin, CONTRACT_OWNER);
        };

        // The remaining coin should equal exactly the total_amount
        let remaining_coin_value = coin::value(&coin);
        
        // If user sent more than needed, refund excess
        if (remaining_coin_value > total_amount) {
            let excess = remaining_coin_value - total_amount;
            let refund_coin = coin::split(&mut coin, excess, ctx);
            sui::transfer::public_transfer(refund_coin, sender);
        };

        let final_coin_value = coin::value(&coin);
        assert!(final_coin_value == total_amount, E_INSUFFICIENT_AMOUNT);

        let droplet_id = generate_droplet_id(sender, current_time, ctx);
        
        // Update fee tracking
        let token_type = get_token_type<CoinType>();
        if (!table::contains(&registry.total_fees_collected, token_type)) {
            table::add(&mut registry.total_fees_collected, token_type, 0);
        };
        let current_fees = table::borrow_mut(&mut registry.total_fees_collected, token_type);
        *current_fees = *current_fees + fee_amount;

        // Create droplet object
        let droplet_uid = object::new(ctx);
        let mut droplet = Droplet<CoinType> {
            id: droplet_uid,
            droplet_id,
            sender,
            total_amount: final_coin_value,
            claimed_amount: 0,
            receiver_limit,
            num_claimed: 0,
            created_at: current_time,
            expiry_time,
            claimed: table::new(ctx),
            device_claims: table::new(ctx),
            claimers_list: vector::empty<address>(),
            claimer_names: vector::empty<String>(),
            coin,
            is_closed: false,
            message,
            distribution_type,
            claim_restriction,
            random_shares: table::new(ctx),
        };

        // Pre-calculate random distribution if needed
        if (distribution_type == DISTRIBUTION_TYPE_RANDOM) {
            precalculate_random_distribution(&mut droplet, ctx);
        };

        let droplet_addr = object::id_address(&droplet);
        table::add(&mut registry.droplets, droplet_id, droplet_addr);
        
        registry.total_droplets_created = registry.total_droplets_created + 1;
        update_user_history(registry, sender, droplet_id, true, ctx);

        event::emit(FeeCollected {
            droplet_id,
            token_type,
            fee_amount,
            recipient: CONTRACT_OWNER,
            timestamp: current_time,
        });

        event::emit(DropletCreated {
            droplet_id,
            droplet_object_id: droplet_addr,
            sender,
            total_amount: total_with_fee,
            net_amount: final_coin_value,
            fee_amount,
            receiver_limit,
            expiry_hours: hours,
            message,
            amount_per_receiver: if (distribution_type == DISTRIBUTION_TYPE_EQUAL) {
                calculate_claim_amount(final_coin_value, receiver_limit)
            } else {
                0
            },
            created_at: current_time,
            expiry_time,
            distribution_type,
            claim_restriction,
        });

        sui::transfer::share_object(droplet);
    }

    entry fun claim_airdrop<CoinType>(
        registry: &mut DropletRegistry,
        droplet: &mut Droplet<CoinType>,
        device_fingerprint: Option<String>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let claimer = tx_context::sender(ctx);
        let current_time = clock::timestamp_ms(clock);

        let claimer_name = if (table::contains(&registry.user_names, claimer)) {
            *table::borrow(&registry.user_names, claimer)
        } else {
            string::utf8(b"Anonymous")
        };

        // Check claim restrictions
        assert!(!droplet.is_closed, E_DROPLET_CLOSED);
        assert!(!table::contains(&droplet.claimed, claimer), E_ALREADY_CLAIMED);
        
        // Check device restriction if enabled
        if (droplet.claim_restriction == CLAIM_RESTRICTION_DEVICE) {
            assert!(option::is_some(&device_fingerprint), E_INVALID_DEVICE_FINGERPRINT);
            let fingerprint = *option::borrow(&device_fingerprint);
            assert!(!table::contains(&droplet.device_claims, fingerprint), E_DEVICE_ALREADY_CLAIMED);
        };

        assert!(droplet.num_claimed < droplet.receiver_limit, E_RECEIVER_LIMIT_REACHED);

        if (current_time >= droplet.expiry_time) {
            cleanup_expired_droplet(droplet, clock, ctx);
            abort E_DROPLET_EXPIRED
        };

        let remaining_balance = coin::value(&droplet.coin);
        assert!(remaining_balance > 0, E_INSUFFICIENT_BALANCE);

        // Calculate claim amount
        let claim_amount = if (droplet.distribution_type == DISTRIBUTION_TYPE_EQUAL) {
            let remaining_receivers = droplet.receiver_limit - droplet.num_claimed;
            calculate_claim_amount(remaining_balance, remaining_receivers)
        } else {
            // Use pre-calculated random share
            *table::borrow(&droplet.random_shares, droplet.num_claimed)
        };

        assert!(claim_amount > 0, E_INSUFFICIENT_BALANCE);

        let final_claim_amount = if (claim_amount > remaining_balance) {
            remaining_balance
        } else {
            claim_amount
        };

        let claim_coin = coin::split(&mut droplet.coin, final_claim_amount, ctx);
        sui::transfer::public_transfer(claim_coin, claimer);

        // Update state
        table::add(&mut droplet.claimed, claimer, claimer_name);
        
        if (droplet.claim_restriction == CLAIM_RESTRICTION_DEVICE && option::is_some(&device_fingerprint)) {
            let fingerprint = *option::borrow(&device_fingerprint);
            table::add(&mut droplet.device_claims, fingerprint, true);
        };
        
        vector::push_back(&mut droplet.claimers_list, claimer);
        vector::push_back(&mut droplet.claimer_names, claimer_name);
        droplet.num_claimed = droplet.num_claimed + 1;
        droplet.claimed_amount = droplet.claimed_amount + final_claim_amount;

        update_user_history(registry, claimer, droplet.droplet_id, false, ctx);

        event::emit(DropletClaimed {
            droplet_id: droplet.droplet_id,
            claimer,
            claimer_name,
            claim_amount: final_claim_amount,
            message: droplet.message,
            claimed_at: current_time,
            device_fingerprint,
        });

        let remaining_after_claim = coin::value(&droplet.coin);
        if (droplet.num_claimed >= droplet.receiver_limit || remaining_after_claim == 0) {
            close_droplet(droplet, string::utf8(b"completed"), current_time, ctx);
        };
    }

    entry fun delete_airdrop<CoinType>(
        droplet: &mut Droplet<CoinType>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        let current_time = clock::timestamp_ms(clock);

        assert!(sender == droplet.sender, E_NOT_CREATOR);
        assert!(droplet.num_claimed == 0, E_CANNOT_DELETE_CLAIMED);
        assert!(!droplet.is_closed, E_DROPLET_CLOSED);

        let refund_amount = coin::value(&droplet.coin);

        if (refund_amount > 0) {
            let refund_coin = coin::split(&mut droplet.coin, refund_amount, ctx);
            sui::transfer::public_transfer(refund_coin, droplet.sender);
        };

        droplet.is_closed = true;

        event::emit(AirdropDeleted {
            droplet_id: droplet.droplet_id,
            sender: droplet.sender,
            refund_amount,
            deleted_at: current_time,
        });
    }

    entry fun cleanup_droplet<CoinType>(
        droplet: &mut Droplet<CoinType>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        assert!(current_time >= droplet.expiry_time, E_DROPLET_EXPIRED);
        assert!(!droplet.is_closed, E_DROPLET_CLOSED);
        
        cleanup_expired_droplet(droplet, clock, ctx);
    }

    fun cleanup_expired_droplet<CoinType>(
        droplet: &mut Droplet<CoinType>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let current_time = clock::timestamp_ms(clock);
        close_droplet(droplet, string::utf8(b"expired"), current_time, ctx);
    }

    fun close_droplet<CoinType>(
        droplet: &mut Droplet<CoinType>,
        reason: String,
        current_time: u64,
        ctx: &mut TxContext
    ) {
        let remaining_balance = coin::value(&droplet.coin);
        
        if (remaining_balance > 0) {
            let refund_coin = coin::split(&mut droplet.coin, remaining_balance, ctx);
            sui::transfer::public_transfer(refund_coin, droplet.sender);
        };
        
        droplet.is_closed = true;
        
        event::emit(DropletClosed {
            droplet_id: droplet.droplet_id,
            sender: droplet.sender,
            refund_amount: remaining_balance,
            total_claimed: droplet.claimed_amount,
            num_claimers: droplet.num_claimed,
            remaining_amount: remaining_balance,
            reason,
            closed_at: current_time,
        });
    }

    entry fun set_fee_percentage(
        _: &AdminCap,
        registry: &mut DropletRegistry,
        new_fee_percentage: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(new_fee_percentage <= 1000, E_INVALID_FEE_PERCENTAGE);
        
        let old_fee = registry.fee_percentage;
        registry.fee_percentage = new_fee_percentage;
        
        event::emit(FeePercentageUpdated {
            old_fee,
            new_fee: new_fee_percentage,
            updated_by: tx_context::sender(ctx),
            timestamp: clock::timestamp_ms(clock),
        });
    }

    // ===== View Functions =====

    public fun get_droplet_info<CoinType>(
        droplet: &Droplet<CoinType>,
        clock: &Clock
    ): DropletInfo {
        let current_time = clock::timestamp_ms(clock);
        let remaining_amount = coin::value(&droplet.coin);
        let is_expired = current_time >= droplet.expiry_time;
        
        DropletInfo {
            droplet_id: droplet.droplet_id,
            sender: droplet.sender,
            total_amount: droplet.total_amount,
            claimed_amount: droplet.claimed_amount,
            remaining_amount,
            receiver_limit: droplet.receiver_limit,
            num_claimed: droplet.num_claimed,
            created_at: droplet.created_at,
            expiry_time: droplet.expiry_time,
            is_expired,
            is_closed: droplet.is_closed,
            message: droplet.message,
            claimers: droplet.claimers_list,
            claimer_names: droplet.claimer_names,
            distribution_type: droplet.distribution_type,
            claim_restriction: droplet.claim_restriction,
        }
    }

    public fun get_user_name(registry: &DropletRegistry, user: address): Option<String> {
        if (table::contains(&registry.user_names, user)) {
            option::some(*table::borrow(&registry.user_names, user))
        } else {
            option::none<String>()
        }
    }

    public fun get_address_by_name(registry: &DropletRegistry, name: String): Option<address> {
        if (table::contains(&registry.name_to_address, name)) {
            option::some(*table::borrow(&registry.name_to_address, name))
        } else {
            option::none<address>()
        }
    }

    public fun is_name_available(registry: &DropletRegistry, name: String): bool {
        !table::contains(&registry.name_to_address, name)
    }

    public fun get_distribution_details<CoinType>(
        droplet: &Droplet<CoinType>
    ): (u8, u8) {
        (droplet.distribution_type, droplet.claim_restriction)
    }

    public fun get_platform_stats(registry: &DropletRegistry): (u64, u64) {
        (registry.total_droplets_created, registry.fee_percentage)
    }

    public fun get_user_history(registry: &DropletRegistry, user: address): (vector<String>, vector<String>) {
        let created = if (table::contains(&registry.user_created_droplets, user)) {
            *table::borrow(&registry.user_created_droplets, user)
        } else {
            vector::empty<String>()
        };
        
        let claimed = if (table::contains(&registry.user_claimed_droplets, user)) {
            *table::borrow(&registry.user_claimed_droplets, user)
        } else {
            vector::empty<String>()
        };
        
        (created, claimed)
    }

    public fun get_user_created_droplets(registry: &DropletRegistry, user: address): vector<String> {
        if (table::contains(&registry.user_created_droplets, user)) {
            *table::borrow(&registry.user_created_droplets, user)
        } else {
            vector::empty<String>()
        }
    }

    public fun get_user_claimed_droplets(registry: &DropletRegistry, user: address): vector<String> {
        if (table::contains(&registry.user_claimed_droplets, user)) {
            *table::borrow(&registry.user_claimed_droplets, user)
        } else {
            vector::empty<String>()
        }
    }

    public fun get_user_created_count(registry: &DropletRegistry, user: address): u64 {
        if (table::contains(&registry.user_created_droplets, user)) {
            let droplets = table::borrow(&registry.user_created_droplets, user);
            vector::length(droplets)
        } else {
            0
        }
    }

    public fun get_user_claimed_count(registry: &DropletRegistry, user: address): u64 {
        if (table::contains(&registry.user_claimed_droplets, user)) {
            let droplets = table::borrow(&registry.user_claimed_droplets, user);
            vector::length(droplets)
        } else {
            0
        }
    }

    public fun get_user_activity_summary(registry: &DropletRegistry, user: address): (vector<String>, vector<String>, u64, u64) {
        let created = get_user_created_droplets(registry, user);
        let claimed = get_user_claimed_droplets(registry, user);
        let created_count = vector::length(&created);
        let claimed_count = vector::length(&claimed);
        
        (created, claimed, created_count, claimed_count)
    }

    public fun user_has_activity(registry: &DropletRegistry, user: address): bool {
        table::contains(&registry.user_created_droplets, user) || 
        table::contains(&registry.user_claimed_droplets, user)
    }

    public fun get_user_created_droplets_paginated(
        registry: &DropletRegistry, 
        user: address, 
        offset: u64, 
        limit: u64
    ): vector<String> {
        if (!table::contains(&registry.user_created_droplets, user)) {
            return vector::empty<String>()
        };
        
        let all_droplets = table::borrow(&registry.user_created_droplets, user);
        let total_length = vector::length(all_droplets);
        
        if (offset >= total_length) {
            return vector::empty<String>()
        };
        
        let mut result = vector::empty<String>();
        let end = if (offset + limit > total_length) { total_length } else { offset + limit };
        let mut i = offset;
        
        while (i < end) {
            vector::push_back(&mut result, *vector::borrow(all_droplets, i));
            i = i + 1;
        };
        
        result
    }

    public fun get_user_claimed_droplets_paginated(
        registry: &DropletRegistry, 
        user: address, 
        offset: u64, 
        limit: u64
    ): vector<String> {
        if (!table::contains(&registry.user_claimed_droplets, user)) {
            return vector::empty<String>()
        };
        
        let all_droplets = table::borrow(&registry.user_claimed_droplets, user);
        let total_length = vector::length(all_droplets);
        
        if (offset >= total_length) {
            return vector::empty<String>()
        };
        
        let mut result = vector::empty<String>();
        let end = if (offset + limit > total_length) { total_length } else { offset + limit };
        let mut i = offset;
        
        while (i < end) {
            vector::push_back(&mut result, *vector::borrow(all_droplets, i));
            i = i + 1;
        };
        
        result
    }

    public fun get_claimers<CoinType>(droplet: &Droplet<CoinType>): (vector<address>, vector<String>) {
        (droplet.claimers_list, droplet.claimer_names)
    }

    public fun has_claimed<CoinType>(droplet: &Droplet<CoinType>, addr: address): bool {
        table::contains(&droplet.claimed, addr)
    }

    public fun has_device_claimed<CoinType>(droplet: &Droplet<CoinType>, device_fingerprint: String): bool {
        table::contains(&droplet.device_claims, device_fingerprint)
    }

    public fun get_remaining_balance<CoinType>(droplet: &Droplet<CoinType>): u64 {
        coin::value(&droplet.coin)
    }

    public fun is_expired<CoinType>(droplet: &Droplet<CoinType>, clock: &Clock): bool {
        let current_time = clock::timestamp_ms(clock);
        current_time >= droplet.expiry_time
    }

    public fun get_droplet_address(registry: &DropletRegistry, droplet_id: String): Option<address> {
        if (table::contains(&registry.droplets, droplet_id)) {
            option::some(*table::borrow(&registry.droplets, droplet_id))
        } else {
            option::none<address>()
        }
    }

    public fun find_droplet_by_id(registry: &DropletRegistry, droplet_id: String): Option<address> {
        assert!(string::length(&droplet_id) == 6, E_INVALID_DROPLET_ID);
        assert!(table::contains(&registry.droplets, droplet_id), E_DROPLET_NOT_FOUND);
        option::some(*table::borrow(&registry.droplets, droplet_id))
    }

    public fun get_fee_percentage(registry: &DropletRegistry): u64 {
        registry.fee_percentage
    }

    public fun can_delete_airdrop<CoinType>(droplet: &Droplet<CoinType>, user: address): bool {
        user == droplet.sender && droplet.num_claimed == 0 && !droplet.is_closed
    }

    public fun get_distribution_type_equal(): u8 {
        DISTRIBUTION_TYPE_EQUAL
    }

    public fun get_distribution_type_random(): u8 {
        DISTRIBUTION_TYPE_RANDOM
    }

    public fun get_claim_restriction_address(): u8 {
        CLAIM_RESTRICTION_ADDRESS
    }

    public fun get_claim_restriction_device(): u8 {
        CLAIM_RESTRICTION_DEVICE
    }

    // Get pre-calculated random share for a specific claim index
    public fun get_random_share<CoinType>(droplet: &Droplet<CoinType>, claim_index: u64): Option<u64> {
        if (droplet.distribution_type == DISTRIBUTION_TYPE_RANDOM && 
            table::contains(&droplet.random_shares, claim_index)) {
            option::some(*table::borrow(&droplet.random_shares, claim_index))
        } else {
            option::none<u64>()
        }
    }

    // Get all pre-calculated random shares (for testing/verification)
    public fun get_all_random_shares<CoinType>(droplet: &Droplet<CoinType>): vector<u64> {
        let mut shares = vector::empty<u64>();
        
        if (droplet.distribution_type == DISTRIBUTION_TYPE_RANDOM) {
            let mut i: u64 = 0;
            while (i < droplet.receiver_limit) {
                if (table::contains(&droplet.random_shares, i)) {
                    vector::push_back(&mut shares, *table::borrow(&droplet.random_shares, i));
                };
                i = i + 1;
            };
        };
        
        shares
    }

    // Verify that random distribution sums correctly
    public fun verify_random_distribution<CoinType>(droplet: &Droplet<CoinType>): (bool, u64, u64) {
        if (droplet.distribution_type != DISTRIBUTION_TYPE_RANDOM) {
            return (false, 0, 0)
        };
        
        let mut total: u64 = 0;
        let mut i: u64 = 0;
        
        while (i < droplet.receiver_limit) {
            if (table::contains(&droplet.random_shares, i)) {
                total = total + *table::borrow(&droplet.random_shares, i);
            };
            i = i + 1;
        };
        
        (total == droplet.total_amount, total, droplet.total_amount)
    }

    // Check if amounts are all distinct
    public fun check_distinct_shares<CoinType>(droplet: &Droplet<CoinType>): bool {
        if (droplet.distribution_type != DISTRIBUTION_TYPE_RANDOM) {
            return false
        };
        
        let shares = get_all_random_shares(droplet);
        let len = vector::length(&shares);
        
        let mut i: u64 = 0;
        while (i < len) {
            let share_i = *vector::borrow(&shares, i);
            let mut j = i + 1;
            
            while (j < len) {
                let share_j = *vector::borrow(&shares, j);
                if (share_i == share_j) {
                    return false
                };
                j = j + 1;
            };
            
            i = i + 1;
        };
        
        true
    }