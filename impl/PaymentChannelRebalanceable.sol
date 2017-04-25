pragma solidity ^0.4.10;

// Note: Initial version does NOT support concurrent conditional payments!

contract PaymentChannelRebalanceable {

    // Blocks for grace period
    uint constant DELTA = 10; 

    // Events
    event EventInit();
    event EventUpdate(int r);
    event LogBytes32(bytes32 b);
    event EventPending(uint T1, uint T2);

    // Utility functions
    modifier onlyplayers {
        if (playermap[msg.sender] > 0)
            _;
        else
            throw;
    }
    function max(uint a, uint b) internal returns(uint) {
        if (a>b)
            return a;
        else
            return b;
    }
    function min(uint a, uint b) internal returns(uint) {
        if (a<b)
            return a;
        else
            return b;
    }
    function verifySignature(address pub, bytes32 h, uint8 v, bytes32 r, bytes32 s) {
        if (pub != ecrecover(h,v,r,s))
            throw;
    }
    function verifyAllSignatures(address[] pub, bytes32 h, uint8[] v, bytes32[] r, bytes32[] s) {
        uint j = (3 - playermap[msg.sender]) - 1;
        address counterParty = players[j];
        bool counterPartyAgrees = false;
        
        for (uint i = 0; i < pub.length; i++) {
            verifySignature(
                pub[i],
                h,
                v[i],      // V
                r[i],      // R
                s[i]);     // S
            
            if (pub[i] == counterParty)
                counterPartyAgrees = true;
        }
        
        if (!counterPartyAgrees)
            throw;
    }
    function verifyMerkleChain(bytes32[] chain) {
        // chain must be [L R L R L R.... T]
        for (uint i = 1; i < chain.length-1; i = i + 2) {
            var hash = sha3(chain[i-1], chain[i]);
            assert((hash == chain[i+1]) || (hash == chain[i+2]));
        }
    }
    
    // Signature struct (hacky way to enable nested array as function param)
    struct Sig {
        uint V;
        uint R;
        uint S;
    }

    ///////////////////////////////
    // State channel data
    ///////////////////////////////
    int bestRound = -1;
    enum Status { OK, PENDING }
    Status public status;
    uint deadline;

    // Constant (set in constructor)
    address[2] public players;
    mapping (address => uint) playermap;    

    /////////////////////////////////////
    // Payment Channel - Application specific data 
    ////////////////////////////////////
    
    // State channel states
    int [2] public credits;
    uint[2] public withdrawals;

    // Externally affected states
    uint[2] public deposits; // Monotonic, only incremented by deposit() function
    uint[2] public withdrawn; // Monotonic, only incremented by withdraw() function

    function sha3int(int r) constant returns(bytes32) {
	    return sha3(r);
    }

    function PaymentChannel(address[2] _players) {
        for (uint i = 0; i < 2; i++) {
            players[i] = _players[i];
            playermap[_players[i]] = i + 1;
        }
        EventInit();
    }

    // Increment on new deposit
    function deposit() payable onlyplayers {
	    deposits[playermap[msg.sender]-1] += msg.value;
    }

    // Increment on withdrawal
    function withdraw() onlyplayers {
    	uint i = playermap[msg.sender]-1;
    	uint toWithdraw = withdrawals[i] - withdrawn[i];
    	withdrawn[i] = withdrawals[i];
    	assert(msg.sender.send(toWithdraw));
    }

    // State channel update function
    function update(uint[3] sig, int r, int[2] _credits, uint[2] _withdrawals)
            onlyplayers {
    	
        // Only update to states with larger round number
        if (r <= bestRound)
            return;
    
        // Check the signature of the other party
    	uint i = (3 - playermap[msg.sender]) - 1;
        var _h = sha3(r, _credits, _withdrawals);
    	var V =  uint8 (sig[0]);
    	var R = bytes32(sig[1]);
    	var S = bytes32(sig[2]);
    	verifySignature(players[i], _h, V, R, S);
    
    	// Update the state
    	credits[0] = _credits[0];
    	credits[1] = _credits[1];
    	withdrawals[0] = _withdrawals[0];
    	withdrawals[1] = _withdrawals[1];
    	bestRound = r;
        EventUpdate(r);
    }
    
    // State channel update function when latest change was due to rebalance
    function updateAfterRebalance(
        uint8[] V,
        bytes32[] R,
        bytes32[] S,
        address[] participants,
        bytes32 instanceHash,
        bytes32[] transactionMerkleChain,
        int r,
        int[2] _credits,
        uint[2] _withdrawals)
            onlyplayers {

        // Only update to states with larger round number
        if (r <= bestRound)
            return;

        // Check the signatures of all parties
        var participantsHash = sha3(participants);
        var treeRoot = transactionMerkleChain[transactionMerkleChain.length-1];
        assert(sha3(participantsHash, treeRoot) == instanceHash);
        verifyAllSignatures(participants, instanceHash, V, R, S);

        // Verify merkle chain
        assert(sha3(r, _credits, _withdrawals) == transactionMerkleChain[0]);
        verifyMerkleChain(transactionMerkleChain);
        
        // Update the state
    	credits[0] = _credits[0];
    	credits[1] = _credits[1];
    	withdrawals[0] = _withdrawals[0];
    	withdrawals[1] = _withdrawals[1];
    	bestRound = r;
        EventUpdate(r);
    }

    // Causes a timeout for the finalize time
    function trigger() onlyplayers {
    	assert( status == Status.OK );
    	status = Status.PENDING;
    	deadline = block.number + DELTA; // Set the deadline for collecting inputs or updates
        EventPending(block.number, deadline);
    }
    
    function finalize() {
    	assert( status == Status.PENDING );
    	assert( block.number > deadline );
    
    	// Note: Is idempotent, may be called multiple times
    
    	// Withdraw the maximum amount of money
    	withdrawals[0] += uint(int(deposits[0]) + credits[0]);
    	withdrawals[1] += uint(int(deposits[1]) + credits[1]);
    	credits[0] = -int(deposits[0]);
    	credits[1] = -int(deposits[1]);
    }
}
