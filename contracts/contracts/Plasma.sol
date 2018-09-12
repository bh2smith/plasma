pragma solidity 0.4.24;

import './libraries/ByteUtils.sol';
import './PriorityQueue.sol';
import './libraries/RLP.sol';
import './libraries/SafeMath.sol';

contract Plasma {
    using SafeMath for uint;
    using RLP for bytes;
    using RLP for RLP.RLPItem;
    using RLP for RLP.Iterator;

    event Deposit(address sender, uint value);
    event SubmitBlock(address sender, bytes32 root);
    event ExitStarted(address sender, uint exitId);
    event ChallengeSuccess(address sender, uint exitId);
    event ChallengeFailure(address sender, uint exitId);
    event FinalizeExit(address sender, uint exitId);
    event DebugBytes32(address sender, bytes32 item);
    event DebugBytes(address sender, bytes item);
    event DebugAddress(address sender, address item);
    event DebugUint(address sender, uint item);
    event DebugBool(address sender, bool item);

    address public authority;
    mapping(uint => ChildBlock) public childChain;
    mapping(uint => Exit) public exits;
    uint public currentChildBlock;
    PriorityQueue public exitQueue;
    uint public lastExitId;
    uint public lastFinalizedTime;

    struct ChildBlock {
        bytes32 root;
        uint created_at;
    }

    struct Exit {
        address owner;
        uint amount;
        uint blocknum;
        uint txindex;
        uint oindex;
        uint started_at;
    }

    constructor () public {
        authority = msg.sender;
        currentChildBlock = 1;
        lastFinalizedTime = block.timestamp;
        exitQueue = new PriorityQueue();
    }

    function submitBlock(bytes32 root) public {
        require(msg.sender == authority);
        childChain[currentChildBlock] = ChildBlock({
            root: root,
            created_at: block.timestamp
        });
        currentChildBlock = currentChildBlock.add(1);

        emit SubmitBlock(msg.sender, root);
    }

    function getBlock(uint blocknum)
        public
        view
        returns (bytes32, uint)
    {
        ChildBlock memory blk = childChain[blocknum];
        return (blk.root, blk.created_at);
    }

    function deposit(bytes txBytes) public payable {
        RLP.RLPItem memory txItem = txBytes.toRLPItem();
        RLP.RLPItem[] memory txList = txItem.toList();

        uint newOwnerIdx = 8;
        uint amountIdx = 9;
        require(msg.sender == txList[newOwnerIdx].toAddress());
        require(msg.value == txList[amountIdx].toUint());

        bytes32 root = createSimpleMerkleRoot(txBytes);

        childChain[currentChildBlock] = ChildBlock({
            root: root,
            created_at: block.timestamp
        });

        currentChildBlock = currentChildBlock.add(1);

        emit Deposit(msg.sender, msg.value);
    }

    function createSimpleMerkleRoot(bytes txBytes) public pure returns (bytes32) {
        // TODO: We may want a different null value.
        bytes32 zeroHash = keccak256(hex"0000000000000000000000000000000000000000000000000000000000000000");
        bytes32 root = keccak256(txBytes);
        
        for (uint i = 0; i < 15; i++) {
            root = keccak256(abi.encodePacked(root, zeroHash));
        }

        return root;
    }

    function startExit(
        uint blocknum,
        uint txindex,
        uint oindex,
        bytes txBytes,
        bytes proof
    ) public
    {
        RLP.RLPItem memory txItem = txBytes.toRLPItem();
        RLP.RLPItem[] memory txList = txItem.toList();

        uint baseIndex = 8 + (oindex * 2);

        require(msg.sender == txList[baseIndex].toAddress());

        uint amount = txList[baseIndex + 1].toUint();
        // Simplify contract by only allowing exits > 0
        require(amount > 0);

        bool exists = checkProof(blocknum, txindex, txBytes, proof);

        require(exists);

        // TODO: check that the sigs given to the utxo owner from the input owner
        // are legit from the side chain.

        uint priority = calcPriority(blocknum, txindex, oindex);
        lastExitId = priority; // For convenience and debugging.
        exitQueue.add(priority);
        
        exits[priority] = Exit({
            owner: msg.sender,
            amount: amount,
            // These are necessary for challenges.
            blocknum: blocknum,
            txindex: txindex,
            oindex: oindex,
            started_at: block.timestamp
        });

        emit ExitStarted(msg.sender, priority);
    }

    function getExit(uint exitId)
        public
        view
        returns (address, uint, uint, uint, uint, uint)
    {
        Exit memory exit = exits[exitId];

        return (exit.owner, exit.amount, exit.blocknum, exit.txindex, exit.oindex, exit.started_at);
    }

    function challengeExit(
        uint exitId,
        uint blocknum,
        uint txindex,
        bytes txBytes,
        bytes proof
    ) 
        public
    {
        Exit memory currExit = exits[exitId];
        RLP.RLPItem memory txItem = txBytes.toRLPItem();
        RLP.RLPItem[] memory txList = txItem.toList();

        bool firstInput = txList[0].toUint() == currExit.blocknum && txList[1].toUint() == currExit.txindex && txList[2].toUint() == currExit.oindex;
        bool secondInput = txList[3].toUint() == currExit.blocknum && txList[4].toUint() == currExit.txindex && txList[5].toUint() == currExit.oindex;

        if(!firstInput && !secondInput) {
            emit ChallengeFailure(msg.sender, exitId);
            return;
        }

        bool exists = checkProof(blocknum, txindex, txBytes, proof);

        if (exists) {
            require(currExit.amount > 0);

            uint burn;
            if (currExit.owner.balance < currExit.amount) {
                burn = currExit.owner.balance;
            } else {
                burn = currExit.amount;
            }

            currExit.owner.transfer(-burn);

            exits[exitId] = Exit({
                owner: address(0),
                amount: 0,
                blocknum: 0,
                txindex: 0,
                oindex: 0,
                started_at: 0
            });

            exitQueue.remove(exitId);

            emit ChallengeSuccess(msg.sender, exitId);
        } else {
            emit ChallengeFailure(msg.sender, exitId);
        }
    }

    // TODO: move into merkle file.
    function checkProof(
        uint blocknum,
        uint txindex,
        bytes txBytes,
        bytes proof
    ) 
        public
        view
        returns (bool)
    {
        // TODO: might need to adjust depth
        require(proof.length == 15 * 32);

        bytes32 root = childChain[blocknum].root;

        bytes32 otherRoot = keccak256(txBytes);

        // Offset for bytes assembly starts at 32
        uint j = 32;

        for(uint i = 0; i < 15; i++) {
            bytes32 sibling;
            assembly {
                sibling := mload(add(proof, j))
            }
            j += 32;

            if (txindex % 2 == 0) {
                otherRoot = keccak256(abi.encodePacked(otherRoot, sibling));
            } else {
                otherRoot = keccak256(abi.encodePacked(sibling, otherRoot));
            }
            
            txindex = txindex / 2;
        }

        return otherRoot == root;
    }

    // TODO: passively finalize.
    // If root node doesn't finalize, and validators finalize,
    // validators have to pay.
    // Finalizing is an expensive operation if the queue is large.
    function finalize() public {
        if (!shouldFinalize()) {
            return;
        }

        lastFinalizedTime = block.timestamp;
        uint exitId = exitQueue.pop();
        while(exitId != SafeMath.max()) {
            Exit memory currExit = exits[exitId];

            if (
                isFinalizableTime(currExit.started_at) &&
                currExit.owner != address(0) &&
                currExit.amount > 0
            ) {
                currExit.owner.transfer(currExit.amount);
                
                exits[exitId] = Exit({
                    owner: address(0),
                    amount: 0,
                    blocknum: 0,
                    txindex: 0,
                    oindex: 0,
                    started_at: 0
                });
                emit FinalizeExit(msg.sender, exitId);
            }

            exitId = exitQueue.pop();
        }
    }

    // Periodically monitor if we should finalize
    function shouldFinalize() public constant returns (bool) {
        // Not used for testing
        return block.timestamp > lastFinalizedTime + 2 days;
        // return true;
    }

    function isFinalizableTime(uint timestamp) public constant returns (bool) {
        // Not used for testing
        return block.timestamp > timestamp + 14 days;
        // return true;
    }

    function calcPriority(
        uint blocknum,
        uint txindex,
        uint oindex
    ) 
        public pure returns (uint) {
        // For now always allow the earliest block to be in the front
        // of the queue.  Don't care about 7 day cliff.
        return blocknum * 1000000000 + txindex * 10000 + oindex;
    }
}
