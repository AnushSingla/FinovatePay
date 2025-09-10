// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./ComplianceManager.sol";

contract EscrowContract is ReentrancyGuard {
    struct Escrow {
        address seller;
        address buyer;
        uint256 amount;
        address token;
        bool sellerConfirmed;
        bool buyerConfirmed;
        bool disputeRaised;
        address disputeResolver;
        uint256 createdAt;
        uint256 expiresAt;
    }
    
    mapping(bytes32 => Escrow) public escrows;
    ComplianceManager public complianceManager;
    address public admin;
    
    event EscrowCreated(bytes32 indexed invoiceId, address seller, address buyer, uint256 amount);
    event DepositConfirmed(bytes32 indexed invoiceId, address buyer, uint256 amount);
    // FIX: Added the 'event' keyword below and capitalized the name for convention
    event EscrowReleased(bytes32 indexed invoiceId, uint256 amount);
    event DisputeRaised(bytes32 indexed invoiceId, address raisedBy);
    event DisputeResolved(bytes32 indexed invoiceId, address resolver, bool sellerWins);
    
    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }
    
    modifier onlyCompliant(address _account) {
        require(!complianceManager.isFrozen(_account), "Account frozen");
        require(complianceManager.isKYCVerified(_account), "KYC not verified");
        _;
    }
    
    constructor(address _complianceManager) {
        admin = msg.sender;
        complianceManager = ComplianceManager(_complianceManager);
    }
    
    function createEscrow(
        bytes32 _invoiceId,
        address _seller,
        address _buyer,
        uint256 _amount,
        address _token,
        uint256 _duration
    ) external onlyAdmin returns (bool) {
        require(escrows[_invoiceId].seller == address(0), "Escrow already exists");
        
        escrows[_invoiceId] = Escrow({
            seller: _seller,
            buyer: _buyer,
            amount: _amount,
            token: _token,
            sellerConfirmed: false,
            buyerConfirmed: false,
            disputeRaised: false,
            disputeResolver: address(0),
            createdAt: block.timestamp,
            expiresAt: block.timestamp + _duration
        });
        
        emit EscrowCreated(_invoiceId, _seller, _buyer, _amount);
        return true;
    }
    
    function deposit(bytes32 _invoiceId, uint256 _amount) external nonReentrant onlyCompliant(msg.sender) {
        Escrow storage escrow = escrows[_invoiceId];
        require(escrow.buyer == msg.sender, "Not the buyer");
        require(_amount == escrow.amount, "Incorrect amount");
        
        IERC20 token = IERC20(escrow.token);
        require(token.transferFrom(msg.sender, address(this), _amount), "Transfer failed");
        
        escrow.buyerConfirmed = true;
        emit DepositConfirmed(_invoiceId, msg.sender, _amount);
    }
    
    function confirmRelease(bytes32 _invoiceId) external nonReentrant {
        Escrow storage escrow = escrows[_invoiceId];
        require(msg.sender == escrow.seller || msg.sender == escrow.buyer, "Not a party to this escrow");
        
        if (msg.sender == escrow.seller) {
            escrow.sellerConfirmed = true;
        } else {
            // Since the first require confirms the sender is either buyer or seller, this else block implies msg.sender is the buyer
            escrow.buyerConfirmed = true;
        }
        
        if (escrow.sellerConfirmed && escrow.buyerConfirmed) {
            _releaseFunds(_invoiceId);
        }
    }
    
    function raiseDispute(bytes32 _invoiceId) external {
        Escrow storage escrow = escrows[_invoiceId];
        require(msg.sender == escrow.seller || msg.sender == escrow.buyer, "Not a party to this escrow");
        require(!escrow.disputeRaised, "Dispute already raised");
        
        escrow.disputeRaised = true;
        emit DisputeRaised(_invoiceId, msg.sender);
    }
    
    function resolveDispute(bytes32 _invoiceId, bool _sellerWins) external onlyAdmin {
        Escrow storage escrow = escrows[_invoiceId];
        require(escrow.disputeRaised, "No dispute raised");
        
        escrow.disputeResolver = msg.sender;
        
        if (_sellerWins) {
            IERC20 token = IERC20(escrow.token);
            require(token.transfer(escrow.seller, escrow.amount), "Transfer to seller failed");
        } else {
            IERC20 token = IERC20(escrow.token);
            require(token.transfer(escrow.buyer, escrow.amount), "Transfer to buyer failed");
        }
        
        emit DisputeResolved(_invoiceId, msg.sender, _sellerWins);
    }
    
    function _releaseFunds(bytes32 _invoiceId) internal {
        Escrow storage escrow = escrows[_invoiceId];
        
        IERC20 token = IERC20(escrow.token);
        require(token.transfer(escrow.seller, escrow.amount), "Transfer failed");
        
        emit EscrowReleased(_invoiceId, escrow.amount);
    }
    
    function expireEscrow(bytes32 _invoiceId) external {
        Escrow storage escrow = escrows[_invoiceId];
        require(block.timestamp >= escrow.expiresAt, "Escrow not expired");
        require(!escrow.sellerConfirmed || !escrow.buyerConfirmed, "Already confirmed");
        
        IERC20 token = IERC20(escrow.token);
        require(token.transfer(escrow.buyer, escrow.amount), "Refund failed");
    }
}