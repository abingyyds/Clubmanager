// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

// Simplified error codes
error TM1(); // Not admin
error TM2(); // Zero address
error TM3(); // Already member
error TM4(); // Wrong price
error TM5(); // Transfer failed
error TM6(); // Not whitelisted
error TM7(); // Transfer not allowed
error TM8(); // Club not initialized
error TM9(); // Club already initialized
error TM10(); // Contract paused
error TM11(); // Invalid operation
error TM12(); // Invalid duration
error TM13(); // Expired membership
error TM14(); // Not a member
error ZeroAddress(string name); // Zero address error
error InvalidTokenId(uint256 tokenId); // Invalid token ID error

// ClubManager interface
interface IClubManager {
    function getClubIdByDomainName(string memory domainName) external view returns (uint256);
    function updateMembership(address user, string memory domainName, bool status) external;
}

/**
 * @title TemporaryMembership
 * @dev Temporary membership contract, directly records wallet address and membership time
 * Based on domain name architecture
 */
contract TemporaryMembership is AccessControl, Pausable, ReentrancyGuard, Ownable {
    using Counters for Counters.Counter;
    using Strings for uint256;
    
    // Address and roles
    address private _clubManager;
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    // Club level data
    struct ClubData {
        address admin;
        bool initialized;
        Policy policy;
        uint256 price;        // Base price (monthly membership)
        uint256 quarterPrice; // Quarterly membership price
        uint256 yearPrice;    // Annual membership price
        address payable receiver;
        uint256 defaultDuration; // Default membership duration (seconds)
        mapping(address => bool) whitelist;
        Counters.Counter memberIdCounter; // Member ID counter
        
        // Club level settings
        string name;
        string symbol;
        string baseURI;
    }
    
    // Optimized member data structure
    struct MemberData {
        uint256 membershipId; // Member ID
        uint256 mintTime;     // Mint time
        uint256 expiryTime;   // Expiry time
        string metadataURI;   // Metadata URI
        bool isMember;        // Whether it's a member
    }
    
    // Domain name to club data mapping
    mapping(string => ClubData) private _clubs;
    
    // Domain name => User address => Member data
    mapping(string => mapping(address => MemberData)) private _members;
    
    // Member TokenID to domain name and user mapping - For compatibility
    mapping(uint256 => address) private _tokenIdToAddress;
    mapping(uint256 => string) private _tokenIdToDomain;
    
    // Transfer strategy
    enum Policy { ALLOW, RESTRICT, WHITELIST }
    
    // Default member validity period (seconds)
    uint256 public defaultDuration = 30 days;
    
    // Membership period enumeration
    enum MembershipPeriod { MONTHLY, QUARTERLY, YEARLY, CUSTOM }
    
    // Events
    event Membership(string indexed domainName, address indexed member, uint256 tokenId, uint256 price, uint256 expiryTime, string action);
    event PolicyChange(string indexed domainName, Policy policy);
    event WhitelistChange(string indexed domainName, address account, bool status);
    event PriceChange(string indexed domainName, MembershipPeriod period, uint256 price);
    event ReceiverChange(string indexed domainName, address receiver);
    event AdminChange(string indexed domainName, address oldAdmin, address newAdmin);
    event ClubInitialized(string indexed domainName, address admin, string name, string symbol, string baseURI);
    event ClubUninitialized(string indexed domainName);
    event DefaultDurationUpdated(uint256 newDuration);
    event ClubSettingUpdated(string indexed domainName, string settingType, string value);
    event AccessRevocationAttempted(string domainName, address user, string reason);
    event MembershipGranted(string domainName, address account, uint256 expiryDate);
    event MembershipRevoked(string domainName, address account);
    event EmergencyPause(bool paused);
    event MembershipGrantAttempted(string domainName, address user, string reason);
    
    modifier onlyClubManagerOrOwner() {
        if (msg.sender != _clubManager && msg.sender != owner()) revert TM1();
        _;
    }
    
    modifier onlyClubAdmin(string memory domainName) {
        string memory standardized = standardizeDomainName(domainName);
        if (msg.sender != _clubs[standardized].admin && msg.sender != owner()) revert TM1();
        _;
    }
    
    modifier clubInitialized(string memory domainName) {
        string memory standardized = standardizeDomainName(domainName);
        if (!_clubs[standardized].initialized) revert TM8();
        _;
    }
    
    modifier whenNotPaused2() {
        if (paused()) revert TM10();
        _;
    }
    
    /**
     * @dev Constructor
     * @param clubManager ClubManager contract address
     */
    constructor(address clubManager) Ownable(msg.sender) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        
        if (clubManager == address(0)) revert ZeroAddress("CM");
        _clubManager = clubManager;
    }
    
    /**
     * @dev For compatibility
     */
    function supportsInterface(bytes4 interfaceId) 
        public 
        view 
        virtual 
        override(AccessControl) 
        returns (bool) 
    {
        return AccessControl.supportsInterface(interfaceId);
    }
    
    /**
     * @dev Returns the URI of the member corresponding to the specified tokenId (For compatibility)
     */
    function uri(uint256 tokenId) public view returns (string memory) {
        address memberAddress = _tokenIdToAddress[tokenId];
        string memory domainName = _tokenIdToDomain[tokenId];
        
        if (memberAddress == address(0) || bytes(domainName).length == 0) {
            return "";
        }
        
        // First check if the member has a custom URI
        string memory customURI = _members[domainName][memberAddress].metadataURI;
        if (bytes(customURI).length > 0) {
            return customURI;
        }
        
        // Use the club's baseURI
        string memory clubBaseURI = _clubs[domainName].baseURI;
        
        // If the club hasn't set baseURI, use the default format
        if (bytes(clubBaseURI).length == 0) {
            return string(abi.encodePacked("https://api.web3club.com/clubs/", domainName, "/members/", tokenId.toString()));
        }
        
        return string(abi.encodePacked(clubBaseURI, tokenId.toString()));
    }
    
    /**
     * @dev Pause and resume the contract
     */
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    // ===== Club initialization and management =====
    
    /**
     * @dev Initialize club
     */
    function initializeClub(
        string memory domainName,
        address admin, 
        string memory name,
        string memory symbol,
        string memory baseURI
    ) external onlyClubManagerOrOwner whenNotPaused2 {
        if (admin == address(0)) revert TM2();
        
        string memory standardized = standardizeDomainName(domainName);
        if (_clubs[standardized].initialized) revert TM9();
        
        ClubData storage club = _clubs[standardized];
        club.admin = admin;
        club.initialized = true;
        club.policy = Policy.ALLOW;
        club.price = 0.01 ether;
        club.quarterPrice = 0.025 ether;
        club.yearPrice = 0.08 ether;
        club.receiver = payable(admin);
        club.defaultDuration = defaultDuration;
        club.name = name;
        club.symbol = symbol;
        club.baseURI = baseURI;
        
        emit ClubInitialized(standardized, admin, name, symbol, baseURI);
    }
    
    /**
     * @dev Simplified initialization function
     */
    function initializeClub(string memory domainName, address admin) external onlyClubManagerOrOwner whenNotPaused2 {
        if (admin == address(0)) revert TM2();
        
        string memory standardized = standardizeDomainName(domainName);
        if (_clubs[standardized].initialized) revert TM9();
        
        // Use domain name to generate default name and symbol
        string memory defaultName = string(abi.encodePacked(standardized, " Temp Membership"));
        string memory defaultSymbol = string(abi.encodePacked(_getSymbol(standardized), "T"));
        string memory defaultBaseURI = string(abi.encodePacked("https://metadata.web3club.com/temp/", standardized, "/"));
        
        ClubData storage club = _clubs[standardized];
        club.admin = admin;
        club.initialized = true;
        club.policy = Policy.ALLOW;
        club.price = 0.01 ether;
        club.quarterPrice = 0.025 ether;
        club.yearPrice = 0.08 ether;
        club.receiver = payable(admin);
        club.defaultDuration = defaultDuration;
        club.name = defaultName;
        club.symbol = defaultSymbol;
        club.baseURI = defaultBaseURI;
        
        emit ClubInitialized(standardized, admin, defaultName, defaultSymbol, defaultBaseURI);
    }
    
    /**
     * @dev Helper function: Generate symbol from domain name
     */
    function _getSymbol(string memory name) internal pure returns (string memory) {
        bytes memory nameBytes = bytes(name);
        uint256 length = nameBytes.length > 5 ? 5 : nameBytes.length;
        
        bytes memory symbolBytes = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            symbolBytes[i] = nameBytes[i];
        }
        
        return string(symbolBytes);
    }
    
    /**
     * @dev Cancel club initialization
     */
    function uninitializeClub(string memory domainName) external onlyClubManagerOrOwner {
        if (!_clubs[domainName].initialized) revert TM8();
        
        _clubs[domainName].initialized = false;
        
        emit ClubUninitialized(domainName);
    }
    
    /**
     * @dev Update club admin
     */
    function updateClubAdmin(string memory domainName, address newAdmin) external onlyClubManagerOrOwner clubInitialized(domainName) whenNotPaused2 {
        if (newAdmin == address(0)) revert TM2();
        
        address oldAdmin = _clubs[domainName].admin;
        _clubs[domainName].admin = newAdmin;
        
        emit AdminChange(domainName, oldAdmin, newAdmin);
    }
    
    /**
     * @dev Check if the club is initialized
     */
    function isClubInitialized(string memory domainName) external view returns (bool initialized, address admin) {
        return (_clubs[domainName].initialized, _clubs[domainName].admin);
    }
    
    /**
     * @dev Get club admin
     */
    function getClubAdmin(string memory domainName) external view clubInitialized(domainName) returns (address) {
        return _clubs[domainName].admin;
    }
    
    // ===== Club settings =====
    
    /**
     * @dev Set club exclusive base URI
     */
    function setClubBaseURI(string memory domainName, string memory newBaseURI) external onlyClubAdmin(domainName) clubInitialized(domainName) whenNotPaused2 {
        _clubs[domainName].baseURI = newBaseURI;
        emit ClubSettingUpdated(domainName, "baseURI", newBaseURI);
    }
    
    /**
     * @dev Update club collection information
     */
    function setCollectionInfo(string memory domainName, string memory _name, string memory _symbol) external onlyClubAdmin(domainName) clubInitialized(domainName) whenNotPaused2 {
        _clubs[domainName].name = _name;
        _clubs[domainName].symbol = _symbol;
        emit ClubSettingUpdated(domainName, "collectionInfo", string(abi.encodePacked(_name, ",", _symbol)));
    }
    
    /**
     * @dev Get club collection information
     */
    function getCollectionInfo(string memory domainName) external view clubInitialized(domainName) returns (string memory, string memory, string memory) {
        return (_clubs[domainName].name, _clubs[domainName].symbol, _clubs[domainName].baseURI);
    }
    
    /**
     * @dev Set member price
     */
    function setPrice(string memory domainName, uint256 _price) external onlyClubAdmin(domainName) clubInitialized(domainName) whenNotPaused2 {
        _clubs[domainName].price = _price;
        emit PriceChange(domainName, MembershipPeriod.MONTHLY, _price);
    }
    
    /**
     * @dev Set quarterly member price
     */
    function setQuarterPrice(string memory domainName, uint256 _price) external onlyClubAdmin(domainName) clubInitialized(domainName) whenNotPaused2 {
        _clubs[domainName].quarterPrice = _price;
        emit PriceChange(domainName, MembershipPeriod.QUARTERLY, _price);
    }
    
    /**
     * @dev Set annual member price
     */
    function setYearPrice(string memory domainName, uint256 _price) external onlyClubAdmin(domainName) clubInitialized(domainName) whenNotPaused2 {
        _clubs[domainName].yearPrice = _price;
        emit PriceChange(domainName, MembershipPeriod.YEARLY, _price);
    }
    
    /**
     * @dev Set funds receiver
     */
    function setReceiver(string memory domainName, address payable _receiver) external onlyClubAdmin(domainName) clubInitialized(domainName) whenNotPaused2 {
        if (_receiver == address(0)) revert TM2();
        _clubs[domainName].receiver = _receiver;
        emit ReceiverChange(domainName, _receiver);
    }
    
    /**
     * @dev Set club default member duration
     */
    function setClubDefaultDuration(string memory domainName, uint256 _duration) external onlyClubAdmin(domainName) clubInitialized(domainName) whenNotPaused2 {
        if (_duration < 1 days) revert TM12();
        _clubs[domainName].defaultDuration = _duration;
        emit ClubSettingUpdated(domainName, "defaultDuration", _duration.toString());
    }
    
    /**
     * @dev Set global default member duration
     */
    function setDefaultDuration(uint256 _duration) external onlyOwner {
        if (_duration < 1 days) revert TM12();
        defaultDuration = _duration;
        emit DefaultDurationUpdated(_duration);
    }
    
    /**
     * @dev Set transfer strategy
     */
    function setPolicy(string memory domainName, Policy _policy) external onlyClubAdmin(domainName) clubInitialized(domainName) whenNotPaused2 {
        _clubs[domainName].policy = _policy;
        emit PolicyChange(domainName, _policy);
    }
    
    /**
     * @dev Set whitelist
     */
    function setWhitelist(string memory domainName, address[] calldata accounts, bool status) external onlyClubAdmin(domainName) clubInitialized(domainName) whenNotPaused2 {
        ClubData storage club = _clubs[domainName];
        
        for (uint256 i = 0; i < accounts.length; i++) {
            club.whitelist[accounts[i]] = status;
            emit WhitelistChange(domainName, accounts[i], status);
        }
    }
    
    // ===== Member qualification management =====
    
    /**
     * @dev Purchase monthly member qualification
     */
    function purchaseMembership(string memory domainName) external payable clubInitialized(domainName) whenNotPaused2 nonReentrant returns (uint256) {
        string memory standardized = standardizeDomainName(domainName);
        ClubData storage club = _clubs[standardized];
        
        // Check price
        if (msg.value != club.price) revert TM4();
        
        // Calculate expiry time
        uint256 expiryTime = block.timestamp + 30 days;
        
        // Execute member registration
        return _registerMembership(standardized, msg.sender, msg.value, expiryTime);
    }
    
    /**
     * @dev Purchase quarterly member qualification
     */
    function purchaseQuarterMembership(string memory domainName) external payable clubInitialized(domainName) whenNotPaused2 nonReentrant returns (uint256) {
        string memory standardized = standardizeDomainName(domainName);
        ClubData storage club = _clubs[standardized];
        
        // Check price
        if (msg.value != club.quarterPrice) revert TM4();
        
        // Calculate expiry time
        uint256 expiryTime = block.timestamp + 90 days;
        
        // Execute member registration
        return _registerMembership(standardized, msg.sender, msg.value, expiryTime);
    }
    
    /**
     * @dev Purchase annual member qualification
     */
    function purchaseYearMembership(string memory domainName) external payable clubInitialized(domainName) whenNotPaused2 nonReentrant returns (uint256) {
        string memory standardized = standardizeDomainName(domainName);
        ClubData storage club = _clubs[standardized];
        
        // Check price
        if (msg.value != club.yearPrice) revert TM4();
        
        // Calculate expiry time
        uint256 expiryTime = block.timestamp + 365 days;
        
        // Execute member registration
        return _registerMembership(standardized, msg.sender, msg.value, expiryTime);
    }
    
    /**
     * @dev Internal member registration function
     */
    function _registerMembership(string memory domainName, address member, uint256 price, uint256 expiryTime) internal returns (uint256) {
        ClubData storage club = _clubs[domainName];
        MemberData storage memberData = _members[domainName][member];
        
        // If already a member, extend membership duration
        if (memberData.isMember && memberData.expiryTime > block.timestamp) {
            // Start extension from current expiry time
            memberData.expiryTime = memberData.expiryTime + (expiryTime - block.timestamp);
        } else {
            // New member or expired member
            // Generate member ID
            club.memberIdCounter.increment();
            uint256 membershipId = club.memberIdCounter.current();
            
            // Calculate unique tokenId (kept for compatibility)
            uint256 tokenId = uint256(keccak256(abi.encodePacked(domainName, membershipId)));
            
            // Record mapping relationship
            _tokenIdToAddress[tokenId] = member;
            _tokenIdToDomain[tokenId] = domainName;
            
            // Update member data
            memberData.membershipId = membershipId;
            memberData.mintTime = block.timestamp;
            memberData.expiryTime = expiryTime;
            memberData.isMember = true;
            
            // Notify ClubManager
            IClubManager(_clubManager).updateMembership(member, domainName, true);
            
            // Emit event
            emit Membership(domainName, member, tokenId, price, expiryTime, "mint");
            
            return tokenId;
        }
        
        // Transfer to receiver
        (bool sent, ) = club.receiver.call{value: price}("");
        if (!sent) revert TM5();
        
        // Emit extension event
        emit Membership(domainName, member, memberData.membershipId, price, memberData.expiryTime, "extend");
        
        return memberData.membershipId;
    }
    
    /**
     * @dev Try to grant membership (according to Web3 spirit, this function no longer supports manual member addition by admin)
     */
    function grantMembership(string memory domainName, address to, uint256 /* duration */) external onlyClubAdmin(domainName) clubInitialized(domainName) whenNotPaused2 returns (uint256) {
        // Record attempt but do not execute actual addition operation
        emit MembershipGrantAttempted(
            domainName,
            to,
            "Operation blocked: Web3 principles require membership through direct purchase only"
        );
        
        // Return 0 to indicate no operation executed
        return 0;
    }
    
    /**
     * @dev Try to batch grant membership (according to Web3 spirit, this function no longer supports manual member addition by admin)
     */
    function grantMemberships(string memory domainName, address[] calldata recipients, uint256 /* duration */) external onlyClubAdmin(domainName) clubInitialized(domainName) whenNotPaused2 {
        // Record attempt but do not execute actual addition operation
        for (uint256 i = 0; i < recipients.length; i++) {
            emit MembershipGrantAttempted(
                domainName,
                recipients[i],
                "Operation blocked: Web3 principles require membership through direct purchase only"
            );
        }
        
        // Return but do not execute any addition operation
        return;
    }
    
    /**
     * @dev Set specific member's metadata URI
     */
    function setMembershipMetadata(string memory domainName, address member, string calldata metadataURI) external onlyClubAdmin(domainName) clubInitialized(domainName) whenNotPaused2 {
        MemberData storage data = _members[domainName][member];
        if (!data.isMember) revert TM14();
        
        data.metadataURI = metadataURI;
    }
    
    /**
     * @dev Try to revoke membership (according to Web3 spirit, this function no longer supports membership revocation by admin)
     */
    function revokeMembership(string memory domainName, address member) external onlyClubAdmin(domainName) clubInitialized(domainName) whenNotPaused2 {
        // Record attempt but do not execute actual revocation operation
        emit AccessRevocationAttempted(
            domainName, 
            member, 
            "Operation blocked: Web3 principles prevent membership revocation"
        );
        
        // Return but do not execute any revocation operation
        return;
    }
    
    /**
     * @dev Try to batch revoke membership (according to Web3 spirit, this function no longer supports membership revocation by admin)
     */
    function revokeMemberships(string memory domainName, address[] calldata members) external onlyClubAdmin(domainName) clubInitialized(domainName) whenNotPaused2 {
        // Record attempt but do not execute actual revocation operation
        for (uint256 i = 0; i < members.length; i++) {
            emit AccessRevocationAttempted(
                domainName, 
                members[i], 
                "Operation blocked: Web3 principles prevent membership revocation"
            );
        }
        
        // Return but do not execute any revocation operation
        return;
    }
    
    // ===== Membership qualification query =====
    
    /**
     * @dev Check membership - following Web3 spirit, once become member always valid
     */
    function hasMembership(string memory domainName, address account) public view clubInitialized(domainName) returns (bool) {
        string memory standardized = standardizeDomainName(domainName);
        MemberData storage data = _members[standardized][account];
        // As long as membership was obtained, it remains valid forever (following Web3 spirit)
        return data.isMember;
    }
    
    /**
     * @dev Check active membership - following Web3 spirit, once become member always valid
     */
    function hasActiveMembership(string memory domainName, address account) public view clubInitialized(domainName) returns (bool) {
        // Ignore expiry time, once become member always valid
        return hasMembership(domainName, account);
    }
    
    /**
     * @dev Get membership expiry time
     */
    function getMembershipExpiry(string memory domainName, address account) external view clubInitialized(domainName) returns (uint256) {
        string memory standardized = standardizeDomainName(domainName);
        return _members[standardized][account].expiryTime;
    }
    
    /**
     * @dev Get member data
     */
    function getMembershipData(string memory domainName, address account) external view clubInitialized(domainName) returns (MemberData memory) {
        string memory standardized = standardizeDomainName(domainName);
        return _members[standardized][account];
    }
    
    /**
     * @dev Get club monthly membership price
     */
    function getClubPrice(string memory domainName) external view clubInitialized(domainName) returns (uint256) {
        string memory standardized = standardizeDomainName(domainName);
        return _clubs[standardized].price;
    }
    
    /**
     * @dev Get club quarterly membership price
     */
    function getClubQuarterPrice(string memory domainName) external view clubInitialized(domainName) returns (uint256) {
        string memory standardized = standardizeDomainName(domainName);
        return _clubs[standardized].quarterPrice;
    }
    
    /**
     * @dev Get club annual membership price
     */
    function getClubYearPrice(string memory domainName) external view clubInitialized(domainName) returns (uint256) {
        string memory standardized = standardizeDomainName(domainName);
        return _clubs[standardized].yearPrice;
    }
    
    /**
     * @dev Get club transfer policy
     */
    function getClubPolicy(string memory domainName) external view clubInitialized(domainName) returns (Policy) {
        return _clubs[domainName].policy;
    }
    
    /**
     * @dev Get club member count (based on member ID counter)
     */
    function getClubMemberCount(string memory domainName) external view clubInitialized(domainName) returns (uint256) {
        return _clubs[domainName].memberIdCounter.current();
    }
    
    /**
     * @dev For query contract used function, get whether member has valid period
     */
    function isMembershipActive(string memory domainName, address account) external view returns (bool) {
        if (!_clubs[domainName].initialized) return false;
        MemberData storage data = _members[domainName][account];
        return data.isMember && data.expiryTime > block.timestamp;
    }
    
    /**
     * @dev Get TokenID from membership ID (kept for compatibility)
     */
    function getTokenIdFromMembershipId(string memory domainName, uint256 membershipId) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(domainName, membershipId)));
    }
    
    /**
     * @dev Receive ETH from error transfer
     */
    receive() external payable {
        emit Membership("refund", msg.sender, 0, msg.value, 0, "refund");
    }

    /**
     * @dev Try to revoke access permission (according to Web3 spirit, this function will not actually revoke membership)
     */
    function revokeAccess(string memory domainName, address account) external 
        clubInitialized(domainName) 
        onlyClubManagerOrOwner {
        
        // Record attempt but do not execute actual revocation operation
        emit AccessRevocationAttempted(domainName, account, "Operation blocked: Web3 principles prevent membership revocation");
        
        // Return but do not execute any revocation operation
        return;
    }

    /**
     * @dev Batch revoke membership (according to Web3 spirit, this function will not actually revoke membership)
     */
    function batchRevokeAccess(string memory domainName, address[] memory accounts) external 
        clubInitialized(domainName) 
        onlyClubManagerOrOwner {
        
        // Record attempt but do not execute actual revocation operation
        for (uint256 i = 0; i < accounts.length; i++) {
            emit AccessRevocationAttempted(domainName, accounts[i], "Operation blocked: Web3 principles prevent membership revocation");
        }
        
        // Return but do not execute any revocation operation
        return;
    }

    /**
     * @dev Compatible old version query interface
     */
    function hasActiveMembershipByDomain(string memory domainName, address account) public view returns (bool) {
        return hasActiveMembership(domainName, account);
    }

    /**
     * @dev Standardize domain name format, ensure domain name is valid and format is uniform
     * @param domainName Input domain name
     * @return Standardized domain name prefix
     */
    function standardizeDomainName(string memory domainName) public pure returns (string memory) {
        bytes memory domainBytes = bytes(domainName);
        
        // If empty return empty
        if (domainBytes.length == 0) return "";
        
        // Remove .web3.club suffix (if exists)
        string memory result = _removeSuffix(domainName);
        domainBytes = bytes(result);
        
        if (domainBytes.length == 0) return "";
        
        // Simple verification of whether characters in domain name are legal
        for (uint i = 0; i < domainBytes.length; i++) {
            bytes1 b = domainBytes[i];
            
            // Allow a-z, 0-9, _ These characters
            if (!(
                (b >= 0x61 && b <= 0x7A) || // a-z
                (b >= 0x30 && b <= 0x39) || // 0-9
                b == 0x5F                    // _
            )) {
                return ""; // Return empty indicates invalid
            }
        }
        
        // Domain name is valid, return prefix
        return result;
    }
    
    /**
     * @dev Remove domain name .web3.club suffix
     * @param fullDomain Possible full domain name containing suffix
     * @return Domain name prefix
     */
    function _removeSuffix(string memory fullDomain) internal pure returns (string memory) {
        bytes memory domainBytes = bytes(fullDomain);
        
        // Check .web3.club suffix
        string memory suffix = ".web3.club";
        bytes memory suffixBytes = bytes(suffix);
        
        if (domainBytes.length <= suffixBytes.length) {
            return fullDomain; // Too short to contain suffix
        }
        
        // Check if it ends with .web3.club
        bool hasSuffix = true;
        for (uint i = 0; i < suffixBytes.length; i++) {
            if (domainBytes[domainBytes.length - suffixBytes.length + i] != suffixBytes[i]) {
                hasSuffix = false;
                break;
            }
        }
        
        if (hasSuffix) {
            // Remove suffix
            bytes memory prefixBytes = new bytes(domainBytes.length - suffixBytes.length);
            for (uint i = 0; i < prefixBytes.length; i++) {
                prefixBytes[i] = domainBytes[i];
            }
            return string(prefixBytes);
        } else {
            // No suffix, directly return
            return fullDomain;
        }
    }
}
