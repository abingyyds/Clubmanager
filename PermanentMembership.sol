// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

// ClubManager interface
interface IClubManager {
    function updateMembership(address user, string memory domainName, bool status) external returns (bool);
    function recordClubPassCollection(string memory domainName, address collectionAddress) external;
}

// Simplified error codes
error NotAdmin();
error ZeroAddress();
error AlreadyMember(); 
error WrongPrice();
error TransferFailed();
error NotWhitelisted();
error TransferNotAllowed(uint256 tokenId);
error ClubNotInitialized();
error ClubAlreadyInitialized();
error ContractPaused();
error InvalidOperation();
error InvalidTokenId(uint256 tokenId);

/**
 * @dev Create independent permanent membership PASS card contract for each CLUB
 * This is a factory contract responsible for creating and tracking PASS card contracts for each CLUB
 */
contract ClubPassFactory is Ownable, Pausable, ReentrancyGuard {
    // ClubManager interface reference
    address public clubManager;
    
    // Record PASS card contract address for each CLUB
    mapping(string => address) public clubPassContracts;
    
    // Record all created PASS card contracts
    address[] public allPassContracts;
    
    // Events
    event ClubPassContractCreated(string indexed domainName, address contractAddress);
    event ClubPassContractRegistered(string indexed domainName, address contractAddress);
    event ProxyPurchase(string indexed domainName, address user, uint256 tokenId);
    event ProxyPriceChanged(string indexed domainName, uint256 price);
    event ProxyReceiverChanged(string indexed domainName, address receiver);
    event ProxyTransferPolicyChanged(string indexed domainName, uint8 policy);
    event ProxyWhitelistChanged(string indexed domainName, address account, bool status);
    
    constructor(address _clubManager) Ownable(msg.sender) {
        if (_clubManager == address(0)) revert ZeroAddress();
        clubManager = _clubManager;
    }
    
    /**
     * @dev Create independent PASS card contract for CLUB
     * @param domainName CLUB domain name
     * @param admin Admin address
     * @param name Contract name
     * @param symbol Contract symbol
     * @param baseURI Base URI
     * @return Created PASS card contract address
     */
    function createClubPassContract(
        string memory domainName,
        address admin,
        string memory name,
        string memory symbol,
        string memory baseURI
    ) external returns (address) {
        // Permission check
        if (msg.sender != clubManager && msg.sender != owner()) {
            revert NotAdmin();
        }
        
        // Ensure CLUB does not already have PASS card contract
        if (clubPassContracts[domainName] != address(0)) {
            revert ClubAlreadyInitialized();
        }
        
        // Create new PASS card contract
        ClubPassCard newContract = new ClubPassCard(
            domainName,
            admin,
            name,
            symbol,
            baseURI,
            clubManager
        );
        
        // Record contract address
        address contractAddress = address(newContract);
        clubPassContracts[domainName] = contractAddress;
        allPassContracts.push(contractAddress);
        
        // Notify ClubManager to record contract address
        try IClubManager(clubManager).recordClubPassCollection(domainName, contractAddress) {} catch {}
        
        // Emit event
        emit ClubPassContractCreated(domainName, contractAddress);
        
        return contractAddress;
    }
    
    /**
     * @dev Get PASS card contract address for CLUB
     * @param domainName CLUB domain name
     * @return PASS card contract address
     */
    function getClubPassContract(string memory domainName) external view returns (address) {
        return clubPassContracts[domainName];
    }
    
    /**
     * @dev Get all PASS card contracts
     * @return All PASS card contract addresses
     */
    function getAllPassContracts() external view returns (address[] memory) {
        return allPassContracts;
    }
    
    /**
     * @dev Proxy purchase permanent membership for specified CLUB
     * @param domainName CLUB domain name
     * @return Member ID
     */
    function purchaseMembershipFor(string memory domainName) external payable nonReentrant whenNotPaused returns (uint256) {
        address passContract = clubPassContracts[domainName];
        if (passContract == address(0)) revert ClubNotInitialized();
        
        // Call proxy purchase function, passing real user address
        (bool success, bytes memory data) = passContract.call{value: msg.value}(
            abi.encodeWithSignature("purchaseMembershipFor(address)", msg.sender)
        );
        
        if (!success) {
            // Handle failure case
            assembly {
                revert(add(data, 32), mload(data))
            }
        }
        
        // Parse return value
        uint256 tokenId = abi.decode(data, (uint256));
        
        emit ProxyPurchase(domainName, msg.sender, tokenId);
        return tokenId;
    }
    
    /**
     * @dev Proxy set member price - Only CLUB admin can call
     * @param domainName CLUB domain name
     * @param newPrice New price
     */
    function setClubPrice(string memory domainName, uint256 newPrice) external whenNotPaused {
        address passContract = clubPassContracts[domainName];
        if (passContract == address(0)) revert ClubNotInitialized();
        
        ClubPassCard clubPass = ClubPassCard(passContract);
        
        // Check if caller is CLUB admin
        if (msg.sender != clubPass.clubAdmin() && msg.sender != owner()) revert NotAdmin();
        
        // Call set price
        clubPass.setPrice(newPrice);
        
        emit ProxyPriceChanged(domainName, newPrice);
    }
    
    /**
     * @dev Proxy set receiver - Only CLUB admin can call
     * @param domainName CLUB domain name
     * @param newReceiver New receiver address
     */
    function setClubReceiver(string memory domainName, address payable newReceiver) external whenNotPaused {
        address passContract = clubPassContracts[domainName];
        if (passContract == address(0)) revert ClubNotInitialized();
        
        ClubPassCard clubPass = ClubPassCard(passContract);
        
        // Check if caller is CLUB admin
        if (msg.sender != clubPass.clubAdmin() && msg.sender != owner()) revert NotAdmin();
        
        // Call set receiver
        clubPass.setReceiver(newReceiver);
        
        emit ProxyReceiverChanged(domainName, newReceiver);
    }
    
    /**
     * @dev Proxy set transfer policy - Only CLUB admin can call
     * @param domainName CLUB domain name
     * @param policy Transfer policy (0=RESTRICT, 1=ALLOW, 2=WHITELIST)
     */
    function setClubTransferPolicy(string memory domainName, uint8 policy) external whenNotPaused {
        if (policy > 2) revert InvalidOperation();
        
        address passContract = clubPassContracts[domainName];
        if (passContract == address(0)) revert ClubNotInitialized();
        
        ClubPassCard clubPass = ClubPassCard(passContract);
        
        // Check if caller is CLUB admin
        if (msg.sender != clubPass.clubAdmin() && msg.sender != owner()) revert NotAdmin();
        
        // Call set transfer policy
        clubPass.setTransferPolicy(ClubPassCard.Policy(policy));
        
        emit ProxyTransferPolicyChanged(domainName, policy);
    }
    
    /**
     * @dev Proxy set whitelist - Only CLUB admin can call
     * @param domainName CLUB domain name
     * @param account Account address
     * @param status Whitelist status
     */
    function setClubWhitelist(string memory domainName, address account, bool status) external whenNotPaused {
        address passContract = clubPassContracts[domainName];
        if (passContract == address(0)) revert ClubNotInitialized();
        
        ClubPassCard clubPass = ClubPassCard(passContract);
        
        // Check if caller is CLUB admin
        if (msg.sender != clubPass.clubAdmin() && msg.sender != owner()) revert NotAdmin();
        
        // Call set whitelist
        clubPass.setWhitelist(account, status);
        
        emit ProxyWhitelistChanged(domainName, account, status);
    }
    
    /**
     * @dev Proxy batch set whitelist - Only CLUB admin can call
     * @param domainName CLUB domain name
     * @param accounts Account address array
     * @param status Whitelist status
     */
    function batchSetClubWhitelist(string memory domainName, address[] calldata accounts, bool status) external whenNotPaused {
        address passContract = clubPassContracts[domainName];
        if (passContract == address(0)) revert ClubNotInitialized();
        
        ClubPassCard clubPass = ClubPassCard(passContract);
        
        // Check if caller is CLUB admin
        if (msg.sender != clubPass.clubAdmin() && msg.sender != owner()) revert NotAdmin();
        
        // Call batch set whitelist
        clubPass.batchSetWhitelist(accounts, status);
        
        for (uint256 i = 0; i < accounts.length; i++) {
            emit ProxyWhitelistChanged(domainName, accounts[i], status);
        }
    }
    
    /**
     * @dev Proxy set contract metadata - Only CLUB admin can call
     * @param domainName CLUB domain name
     * @param _name Name
     * @param _symbol Symbol
     * @param _description Description
     */
    function setClubContractInfo(string memory domainName, string memory _name, string memory _symbol, string memory _description) external whenNotPaused {
        address passContract = clubPassContracts[domainName];
        if (passContract == address(0)) revert ClubNotInitialized();
        
        ClubPassCard clubPass = ClubPassCard(passContract);
        
        // Check if caller is CLUB admin
        if (msg.sender != clubPass.clubAdmin() && msg.sender != owner()) revert NotAdmin();
        
        // Call set contract information
        clubPass.setContractInfo(_name, _symbol, _description);
    }
    
    /**
     * @dev Proxy set media information - Only CLUB admin can call
     * @param domainName CLUB domain name
     * @param _logoURI Logo URI
     * @param _bannerURI Banner URI
     */
    function setClubMedia(string memory domainName, string memory _logoURI, string memory _bannerURI) external whenNotPaused {
        address passContract = clubPassContracts[domainName];
        if (passContract == address(0)) revert ClubNotInitialized();
        
        ClubPassCard clubPass = ClubPassCard(passContract);
        
        // Check if caller is CLUB admin
        if (msg.sender != clubPass.clubAdmin() && msg.sender != owner()) revert NotAdmin();
        
        // Call set media information
        clubPass.setMedia(_logoURI, _bannerURI);
    }
    
    /**
     * @dev Proxy set base URI - Only CLUB admin can call
     * @param domainName CLUB domain name
     * @param _baseURI New base URI
     */
    function setClubBaseURI(string memory domainName, string memory _baseURI) external whenNotPaused {
        address passContract = clubPassContracts[domainName];
        if (passContract == address(0)) revert ClubNotInitialized();
        
        ClubPassCard clubPass = ClubPassCard(passContract);
        
        // Check if caller is CLUB admin
        if (msg.sender != clubPass.clubAdmin() && msg.sender != owner()) revert NotAdmin();
        
        // Call set base URI
        clubPass.setBaseURI(_baseURI);
    }
    
    /**
     * @dev Proxy set member metadata - Only CLUB admin can call
     * @param domainName CLUB domain name
     * @param tokenId Token ID
     * @param metadataURI Metadata URI
     */
    function setClubMembershipMetadata(string memory domainName, uint256 tokenId, string calldata metadataURI) external whenNotPaused {
        address passContract = clubPassContracts[domainName];
        if (passContract == address(0)) revert ClubNotInitialized();
        
        ClubPassCard clubPass = ClubPassCard(passContract);
        
        // Check if caller is CLUB admin
        if (msg.sender != clubPass.clubAdmin() && msg.sender != owner()) revert NotAdmin();
        
        // Call set member metadata
        clubPass.setMembershipMetadata(tokenId, metadataURI);
    }
    
    /**
     * @dev Query member and contract related information
     */
    function queryClubMembership(
        string memory domainName, 
        address account
    ) external view returns (
        bool isMember,
        bool isActive,
        uint256 tokenId,
        uint256 memberCount
    ) {
        address passContract = clubPassContracts[domainName];
        if (passContract == address(0)) return (false, false, 0, 0);
        
        ClubPassCard clubPass = ClubPassCard(passContract);
        return (
            clubPass.hasMembership(account),
            clubPass.hasActiveMembership(account),
            clubPass.getMemberTokenId(account),
            clubPass.getMemberCount()
        );
    }
    
    /**
     * @dev Check contract configuration and domain PASS status
     */
    function checkConfig(string memory domainName) external view returns (
        address clubManagerAddress,
        address factoryOwner,
        bool hasContract,
        address contractAddress
    ) {
        address passContract = clubPassContracts[domainName];
        return (
            clubManager, 
            owner(),
            passContract != address(0),
            passContract
        );
    }
    
    /**
     * @dev Emergency pause
     */
    function emergencyPause() external onlyOwner { _pause(); }
    
    /**
     * @dev Cancel emergency pause
     */
    function emergencyUnpause() external onlyOwner { _unpause(); }
    
    /**
     * @dev Update ClubManager address
     * @param _clubManager New ClubManager address
     */
    function updateClubManager(address _clubManager) external onlyOwner {
        if (_clubManager == address(0)) revert ZeroAddress();
        clubManager = _clubManager;
    }
}

/**
 * @title ClubPassCard
 * @dev Each CLUB's independent permanent membership PASS card contract
 * Each contract instance manages a single CLUB's permanent membership
 */
contract ClubPassCard is ERC1155, Ownable, Pausable, ReentrancyGuard {
    using Counters for Counters.Counter;
    
    // CLUB information
    string public domainName;
    address public clubAdmin;
    address public clubManager;
    
    // Contract information
    string public name;
    string public symbol;
    string public baseURI;
    string public description;
    string public logoURI;
    string public bannerURI;
    
    // Member card settings
    uint256 public price;
    
    // Transfer policy
    enum Policy { 
        RESTRICT,    // Prohibit transfer
        ALLOW,       // Allow free transfer
        WHITELIST    // Whitelist control transfer
    }
    Policy public transferPolicy;
    
    // Whitelist
    mapping(address => bool) public whitelist;
    
    // Member ID counter
    Counters.Counter private _memberIdCounter;
    
    // Member data
    struct MemberData {
        address owner;
        uint256 membershipId;
        uint256 mintTime;
        string metadataURI;
    }
    
    // Member mapping
    mapping(address => bool) public members;
    mapping(uint256 => MemberData) private _memberData;
    mapping(address => uint256) private _memberTokenIds;
    
    // Payment receiver
    address payable public receiver;
    
    // Events
    event Minted(address to, uint256 tokenId, uint256 price);
    event PolicyChanged(Policy policy);
    event WhitelistChanged(address account, bool status);
    event PriceChanged(uint256 price);
    event ReceiverChanged(address receiver);
    event AdminChanged(address prev, address next);
    event BaseURIUpdated(string newBaseURI);
    event MetadataUpdated(uint256 tokenId, string metadataURI);
    event ContractInfoUpdated(string name, string symbol, string description);
    event MediaUpdated(string logoURI, string bannerURI);
    
    modifier onlyClubAdmin() {
        if (msg.sender != clubAdmin && msg.sender != owner()) revert NotAdmin();
        _;
    }
    
    constructor(
        string memory _domainName,
        address _admin,
        string memory _name,
        string memory _symbol,
        string memory _baseURI,
        address _clubManager
    ) ERC1155(_baseURI) Ownable(msg.sender) {
        if (_admin == address(0)) revert ZeroAddress();
        if (_clubManager == address(0)) revert ZeroAddress();
        
        domainName = _domainName;
        clubAdmin = _admin;
        clubManager = _clubManager;
        name = _name;
        symbol = _symbol;
        baseURI = _baseURI;
        price = 0.1 ether;
        transferPolicy = Policy.RESTRICT;
        receiver = payable(_admin);
        
        // Start from 1
        _memberIdCounter.increment();
    }
    
    /**
     * @dev Purchase membership qualification
     */
    function purchaseMembership() external payable whenNotPaused nonReentrant returns (uint256) {
        if (msg.value != price) revert WrongPrice();
        if (members[msg.sender]) revert AlreadyMember();
        
        uint256 membershipId = _memberIdCounter.current();
        _memberIdCounter.increment();
        
        _memberData[membershipId] = MemberData({
            owner: msg.sender,
            membershipId: membershipId,
            mintTime: block.timestamp,
            metadataURI: ""
        });
        
        _memberTokenIds[msg.sender] = membershipId;
        members[msg.sender] = true;
        
        _mint(msg.sender, membershipId, 1, "");
        
        try IClubManager(clubManager).updateMembership(msg.sender, domainName, true) {} catch {}
        
        emit Minted(msg.sender, membershipId, msg.value);
        
        (bool sent, ) = receiver.call{value: msg.value}("");
        if (!sent) revert TransferFailed();
        
        return membershipId;
    }
    
    /**
     * @dev Proxy purchase membership qualification - Allow factory contract to represent user purchase
     * @param _receiver Address to receive membership qualification
     * @return Member ID
     */
    function purchaseMembershipFor(address _receiver) external payable whenNotPaused nonReentrant returns (uint256) {
        if (msg.value != price) revert WrongPrice();
        if (members[_receiver]) revert AlreadyMember();
        
        uint256 membershipId = _memberIdCounter.current();
        _memberIdCounter.increment();
        
        _memberData[membershipId] = MemberData({
            owner: _receiver,
            membershipId: membershipId,
            mintTime: block.timestamp,
            metadataURI: ""
        });
        
        _memberTokenIds[_receiver] = membershipId;
        members[_receiver] = true;
        
        _mint(_receiver, membershipId, 1, "");
        
        try IClubManager(clubManager).updateMembership(_receiver, domainName, true) {} catch {}
        
        emit Minted(_receiver, membershipId, msg.value);
        
        (bool sent, ) = receiver.call{value: msg.value}("");
        if (!sent) revert TransferFailed();
        
        return membershipId;
    }
    
    /**
     * @dev Override token transfer processing function before
     */
    function _beforeTokenTransfer(
        address /* operator */,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory /* amounts */,
        bytes memory /* data */
    ) internal virtual {
        if (from == address(0)) return;
        
        if (transferPolicy == Policy.RESTRICT) {
            revert TransferNotAllowed(ids[0]);
        } else if (transferPolicy == Policy.WHITELIST) {
            if (!whitelist[from] && !whitelist[to]) {
                revert NotWhitelisted();
            }
        }
    }
    
    /**
     * @dev Update member qualification NFT transfer record after
     */
    function _afterTokenTransfer(
        address /* operator */,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory /* amounts */,
        bytes memory /* data */
    ) internal virtual {
        if (from == address(0) || to == address(0)) return;
        
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 tokenId = ids[i];
            
            members[from] = false;
            members[to] = true;
            
            _memberData[tokenId].owner = to;
            
            _memberTokenIds[from] = 0;
            _memberTokenIds[to] = tokenId;
            
            try IClubManager(clubManager).updateMembership(from, domainName, false) {} catch {}
            try IClubManager(clubManager).updateMembership(to, domainName, true) {} catch {}
        }
    }
    
    /**
     * @dev Merge member query to reduce code size
     */
    function hasMembership(address account) public view returns (bool) {
        return members[account];
    }
    
    function hasActiveMembership(address account) public view returns (bool) {
        return members[account];
    }
    
    /**
     * @dev Simplified domain check to reduce code size
     */
    function hasActiveMembershipByDomain(string memory _domainName, address account) public view returns (bool) {
        // Simplified domain processing logic, only check if it matches current domain
        string memory domain = _domainName;
        string memory suffix = ".web3.club";
        
        // If it has .web3.club suffix, remove suffix
        bytes memory inputBytes = bytes(_domainName);
        bytes memory suffixBytes = bytes(suffix);
        if (inputBytes.length > suffixBytes.length) {
            uint256 prefixLength = inputBytes.length - suffixBytes.length;
            bool hasSuffix = true;
            
            for (uint i = 0; i < suffixBytes.length; i++) {
                if (inputBytes[prefixLength + i] != suffixBytes[i]) {
                    hasSuffix = false;
                    break;
                }
            }
            
            if (hasSuffix) {
                bytes memory prefixBytes = new bytes(prefixLength);
                for (uint i = 0; i < prefixLength; i++) {
                    prefixBytes[i] = inputBytes[i];
                }
                domain = string(prefixBytes);
            }
        }
        
        if (keccak256(bytes(domain)) == keccak256(bytes(domainName))) {
            return members[account];
        }
        return false;
    }
    
    function setPrice(uint256 _price) external onlyClubAdmin whenNotPaused {
        price = _price;
        emit PriceChanged(_price);
    }
    
    function setReceiver(address payable _receiver) external onlyClubAdmin whenNotPaused {
        if (_receiver == address(0)) revert ZeroAddress();
        receiver = _receiver;
        emit ReceiverChanged(_receiver);
    }
    
    function setTransferPolicy(Policy _policy) external onlyClubAdmin whenNotPaused {
        transferPolicy = _policy;
        emit PolicyChanged(_policy);
    }
    
    function setWhitelist(address account, bool status) external onlyClubAdmin whenNotPaused {
        whitelist[account] = status;
        emit WhitelistChanged(account, status);
    }
    
    function batchSetWhitelist(address[] calldata accounts, bool status) external onlyClubAdmin whenNotPaused {
        for (uint256 i = 0; i < accounts.length; i++) {
            whitelist[accounts[i]] = status;
            emit WhitelistChanged(accounts[i], status);
        }
    }
    
    function updateAdmin(address newAdmin) external {
        if (msg.sender != clubManager && msg.sender != clubAdmin && msg.sender != owner()) {
            revert NotAdmin();
        }
        
        if (newAdmin == address(0)) revert ZeroAddress();
        
        address oldAdmin = clubAdmin;
        clubAdmin = newAdmin;
        
        emit AdminChanged(oldAdmin, newAdmin);
    }
    
    function setMembershipMetadata(uint256 tokenId, string calldata metadataURI) external onlyClubAdmin whenNotPaused {
        if (_memberData[tokenId].owner == address(0)) revert InvalidTokenId(tokenId);
        
        _memberData[tokenId].metadataURI = metadataURI;
        emit MetadataUpdated(tokenId, metadataURI);
    }
    
    function setBaseURI(string memory _baseURI) external onlyClubAdmin whenNotPaused {
        baseURI = _baseURI;
        emit BaseURIUpdated(_baseURI);
    }
    
    function setContractInfo(string memory _name, string memory _symbol, string memory _description) external onlyClubAdmin whenNotPaused {
        name = _name;
        symbol = _symbol;
        description = _description;
        emit ContractInfoUpdated(_name, _symbol, _description);
    }
    
    function setMedia(string memory _logoURI, string memory _bannerURI) external onlyClubAdmin whenNotPaused {
        logoURI = _logoURI;
        bannerURI = _bannerURI;
        emit MediaUpdated(_logoURI, _bannerURI);
    }
    
    function getMemberCount() external view returns (uint256) {
        return _memberIdCounter.current() - 1;
    }
    
    function getMemberTokenId(address account) external view returns (uint256) {
        return _memberTokenIds[account];
    }
    
    /**
     * @dev Simplified token URI generation
     */
    function uri(uint256 tokenId) public view override returns (string memory) {
        if (_memberData[tokenId].owner == address(0)) return "";
        
        if (bytes(_memberData[tokenId].metadataURI).length > 0) {
            return _memberData[tokenId].metadataURI;
        }
        
        if (bytes(baseURI).length > 0) {
            return string(abi.encodePacked(baseURI, "tokens/", _toString(tokenId)));
        }
        
        return string(abi.encodePacked(
            "https://metadata.web3club.com/collections/", 
            domainName,
            "/tokens/",
            _toString(tokenId)
        ));
    }
    
    function emergencyPause() external onlyOwner { _pause(); }
    function emergencyUnpause() external onlyOwner { _unpause(); }
    
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        
        return string(buffer);
    }
}