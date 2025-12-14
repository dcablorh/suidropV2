module airdrop::admin;
    use sui::hash;
    use sui::address;
    use sui::bcs;
    use std::string::{Self, String};

    public struct AdminCap has key {
        id: UID,
    }

    fun init(ctx: &mut TxContext) {
        let admin_cap = AdminCap {
            id: object::new(ctx),
        };
        sui::transfer::transfer(admin_cap, tx_context::sender(ctx));
    }

    public fun generate_droplet_id(sender: address, timestamp: u64, ctx: &mut TxContext): String {
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
