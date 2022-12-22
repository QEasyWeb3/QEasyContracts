//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;
import "./library/Initializable.sol";
import "./SystemContract.sol";

contract OnChainDao is Initializable {
    address public constant SystemContractAddr = address(0x000000000000000000000000000000000000f000);
    uint256 public proposalLastingPeriod = 7 days;
    enum VoteState {
        Unknown,
        Agree,
        Reject
    }

    uint8 ExecuteProposal = 0;
    uint8 DeleteCode = 1;

    struct ProposalInfo {
        uint8 action;
        address from;
        address to;
        uint256 value;
        bytes data;
    }

    struct Proposal {
        uint256 id;
        address proposer;
        ProposalInfo info;
        uint256 createTime;
        uint16 agreeCount;
        uint16 rejectCount;
        VoteState state;
    }

    struct VoteInfo {
        uint256 voteTime;
        bool result;
    }

    address public admin;
    SystemContract systemContract;
    Proposal[] public proposals;
    uint256[] public passedProposalIds;
    mapping(uint256 => mapping(address => VoteInfo)) public votes;

    event AdminChanged(address indexed newAdmin);
    event ProposalCommitted(uint256 indexed id);
    event ProposalFinished(uint256 indexed id);
    event LogVote(uint256 indexed id, address indexed voter, bool result, uint256 time);
    event LogProposalResult(uint256 indexed id, bool result, uint256 time);

    modifier onlyAdmin() {
        require(msg.sender == admin, "E02");
        _;
    }

    modifier onlyLocal() {
        require(msg.sender == address(0x0000000000000000000000000000000000000000), "E00");
        _;
    }

    modifier onlyActiveValidator() {
        require(systemContract.isActiveValidator(msg.sender), "E22");
        _;
    }

    modifier onlyAllowed() {
        require(systemContract.isActiveValidator(msg.sender) || msg.sender == admin, "E27");
        _;
    }

    function initialize(address _admin) external initializer {
        admin = _admin;
        systemContract = SystemContract(SystemContractAddr);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        admin = newAdmin;
        emit AdminChanged(newAdmin);
    }

    function commitProposal(uint8 action, address from, address to, uint value, bytes calldata input) external onlyAllowed {
        require(action >= ExecuteProposal && action <= DeleteCode, "E28");
        uint id = proposals.length;
        ProposalInfo memory info = ProposalInfo(action, from, to, value, input);
        VoteState state = VoteState.Unknown;
        if (msg.sender == admin) {
            passedProposalIds.push(id);
            state = VoteState.Agree;
            emit LogProposalResult(id, true, block.timestamp);
        }
        Proposal memory p = Proposal(id, msg.sender, info, block.timestamp, 0, 0, state);
        proposals.push(p);
        emit ProposalCommitted(id);
    }

    function voteProposal(uint id, bool result) external onlyActiveValidator {
        require(proposals[id].createTime != 0, "E23");
        require(proposals[id].state == VoteState.Unknown, "E26");
        require(votes[id][msg.sender].voteTime == 0, "E24");
        require(block.timestamp < proposals[id].createTime + proposalLastingPeriod, "E25");

        votes[id][msg.sender].voteTime = block.timestamp;
        votes[id][msg.sender].result = result;
        emit LogVote(id, msg.sender, result, block.timestamp);
        if (result) {
            proposals[id].agreeCount = proposals[id].agreeCount + 1;
        } else {
            proposals[id].rejectCount = proposals[id].rejectCount + 1;
        }
        if (proposals[id].agreeCount >= systemContract.getActiveValidators().length / 2 + 1) {
            proposals[id].state = VoteState.Agree;
            passedProposalIds.push(id);
            emit LogProposalResult(id, true, block.timestamp);
        } else if (proposals[id].rejectCount >= systemContract.getActiveValidators().length / 2 + 1) {
            proposals[id].state = VoteState.Reject;
            emit LogProposalResult(id, false, block.timestamp);
        }
    }

    function getProposalsTotalCount() view external returns (uint) {
        return proposals.length;
    }

    function getProposalById(uint id) view external returns (
        uint _id,
        uint8 action,
        address from,
        address to,
        uint value,
        bytes memory data) {
        require(id < proposals.length, "Id does not exist");

        Proposal memory p = proposals[id];
        ProposalInfo memory info = p.info;
        return (p.id, info.action, info.from, info.to, info.value, info.data);
    }

    function getPassedProposalCount() view external returns (uint32) {
        return uint32(passedProposalIds.length);
    }

    function getPassedProposalByIndex(uint32 index) view external returns (
        uint256 id,
        uint8 action,
        address from,
        address to,
        uint value,
        bytes memory data) {
        require(index < passedProposalIds.length, "Index out of range");

        uint256 pId = passedProposalIds[index];
        Proposal memory p = proposals[pId];
        ProposalInfo memory info = p.info;
        return (p.id, info.action, info.from, info.to, info.value, info.data);
    }

    function finishProposalById(uint id) external onlyLocal {
        for (uint i = 0; i < passedProposalIds.length; i++) {
            if (passedProposalIds[i] == id) {
                if (i != passedProposalIds.length - 1) {
                    passedProposalIds[i] = passedProposalIds[passedProposalIds.length - 1];
                }
                passedProposalIds.pop();
                emit ProposalFinished(id);
                break;
            }
        }
    }
}
