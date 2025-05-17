// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Use named imports, only import the contract itself, avoid interface duplicate declarations
import {ClubManager} from "./ClubManager.sol";
import "./PermanentMembership.sol";
import {TemporaryMembership} from "./TemporaryMembership.sol";
import {TokenBasedAccess, IMembershipQuery} from "./TokenBasedAccess.sol";  // Import interface directly from TokenBasedAccess

// Define custom errors
error CMQNotAuthorized();
error CMQInvalidDomain(string domainName);

enum TokenType { ERC20, ERC721, ERC1155, CROSSCHAIN }

/**
 * @title ClubMembershipQuery
 * @dev Provides query functions for club memberships
 */
contract ClubMembershipQuery {
    ClubManager private _clubManager;
    ClubPassFactory private _passFactory;
    TemporaryMembership private _tempMembership;
    TokenBasedAccess private _tokenAccess;
    
    struct MembershipStatus {
        bool isMember;
        uint256 expirationDate; // 0 indicates permanent member or token-based member
        string membershipType;  // "permanent", "temporary", "token-based"
    }
    
    struct ClubMembershipConditions {
        // Club basic information
        string clubName;
        address clubOwner;
        
        // Permanent membership information
        address permanentMembershipContract;
        bool hasPermanentMembership;
        
        // Token requirements
        address tokenAddress;
        uint256 requiredTokenAmount;
        bool isNFT;
        bool hasTokenRequirement;
        
        // Temporary membership information
        address temporaryMembershipContract;
        uint256 membershipPrice;
        uint256 quarterPrice;
        uint256 yearPrice;
        
        // 修改为数组结构
        TokenRequirement[] tokenRequirements;
    }
    
    struct TokenRequirement {
        address tokenAddress;
        uint256 requiredAmount;
        bool isNFT;
        uint8 tokenType;  // 对应TokenType枚举
        string chainId;
        string symbol;
    }
    
    constructor(address clubManager) {
        _clubManager = ClubManager(clubManager);
        
        // Use getClubContracts to get contract addresses
        (address pass, address temp, address token) = ClubManager(clubManager).getClubContracts("");
        
        _passFactory = ClubPassFactory(payable(pass));
        _tempMembership = TemporaryMembership(payable(temp));
        _tokenAccess = TokenBasedAccess(token);
    }
    
    /**
     * @dev Standardize domain name format, ensure domain name is valid and format is unified
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
        
        // Simple validation of characters in domain name
        for (uint i = 0; i < domainBytes.length; i++) {
            bytes1 b = domainBytes[i];
            
            // Allow a-z, 0-9, _ characters
            if (!(
                (b >= 0x61 && b <= 0x7A) || // a-z
                (b >= 0x30 && b <= 0x39) || // 0-9
                b == 0x5F                    // _
            )) {
                return ""; // Return empty to indicate invalid
            }
        }
        
        // Domain name is valid, return prefix
        return result;
    }
    
    /**
     * @dev Remove .web3.club suffix
     * @param fullDomain Full domain name that may contain suffix
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
            // No suffix, return directly
            return fullDomain;
        }
    }
    
    /**
     * @dev Get CLUB's PASS card contract address through ClubPassFactory
     * @param domainName Domain name
     * @return passAddress PASS card contract address
     */
    function getClubPassAddress(string memory domainName) public view returns (address passAddress) {
        try _passFactory.getClubPassContract(domainName) returns (address addr) {
            return addr;
        } catch {
            return address(0);
        }
    }
    
    /**
     * @dev Check user's membership status in PASS card contract
     * @param domainName Domain name
     * @param user User address
     * @return Whether is a member
     */
    function checkPassCardMembership(string memory domainName, address user) public view returns (bool) {
        address passAddr = getClubPassAddress(domainName);
        if (passAddr == address(0)) return false;
        
        try ClubPassCard(passAddr).hasMembership(user) returns (bool result) {
            return result;
        } catch {
            return false;
        }
    }
    
    /**
     * @dev Check if a user is a member of a specific club
     * @param domainName Domain name of the club
     * @param user Address of the user
     * @return memberStatus Whether the user is a member
     */
    function isMember(string memory domainName, address user) external view returns (bool memberStatus) {
        string memory standardized = standardizeDomainName(domainName);
        if (!_isDomainValid(standardized)) return false;
        return _clubManager.isMember(standardized, user);
    }
    
    /**
     * @dev Get all clubs a user is a member of
     * @param user Address of the user
     * @return userClubs Array of club domain names
     */
    function getUserClubs(address user) external view returns (string[] memory userClubs) {
        return _clubManager.getUserClubs(user);
    }
    
    /**
     * @dev Get all clubs joined by the user and their expiration dates
     * @param user User address
     * @return domainNames Array of club domain names
     * @return statuses Array of corresponding membership statuses
     */
    function getUserMemberships(address user) public view returns (string[] memory domainNames, MembershipStatus[] memory statuses) {
        string[] memory userClubs = _clubManager.getUserClubs(user);
        domainNames = userClubs;
        statuses = new MembershipStatus[](userClubs.length);
        
        for (uint256 i = 0; i < userClubs.length; i++) {
            (bool isClubMember, uint256 expiration, string memory memberType) = _checkMembership(user, userClubs[i]);
            statuses[i] = MembershipStatus(isClubMember, expiration, memberType);
        }
        
        return (domainNames, statuses);
    }
    
    /**
     * @dev Check user's membership status in a specific club
     * @param user User address
     * @param domainName Domain name of the club
     * @return status Membership status
     */
    function checkUserMembership(address user, string memory domainName) public view returns (MembershipStatus memory status) {
        string memory standardized = standardizeDomainName(domainName);
        if (!_isDomainValid(standardized)) {
            return MembershipStatus(false, 0, "");
        }
        
        (bool memberStatus, uint256 expiration, string memory memberType) = _checkMembership(user, standardized);
        return MembershipStatus(memberStatus, expiration, memberType);
    }
    
    /**
     * @dev Get club membership conditions
     * @param domainName Domain name of the club
     * @return conditions Club membership conditions
     */
    function getClubMembershipConditions(string memory domainName) public view returns (ClubMembershipConditions memory conditions) {
        string memory standardized = standardizeDomainName(domainName);
        if (!_isDomainValid(standardized)) revert CMQInvalidDomain(standardized);
        
        // Initialize return structure with default values
        conditions.clubName = standardized;
        conditions.clubOwner = _clubManager.getClubAdmin(standardized);
        
        // Get shared contracts
        (address perm, address temp, address token) = _clubManager.getClubContracts(standardized);
        
        // Permanent membership information
        address passContract = getClubPassAddress(standardized);
        conditions.permanentMembershipContract = passContract != address(0) ? passContract : perm;
        conditions.hasPermanentMembership = true;
        
        // Temporary membership information
        conditions.temporaryMembershipContract = temp;
        if (temp != address(0)) {
            conditions.membershipPrice = _tempMembership.getClubPrice(standardized);
            conditions.quarterPrice = _tempMembership.getClubQuarterPrice(standardized);
            conditions.yearPrice = _tempMembership.getClubYearPrice(standardized);
        } else {
            conditions.membershipPrice = 0;
            conditions.quarterPrice = 0;
            conditions.yearPrice = 0;
        }
        
        // Token requirements
        conditions.tokenAddress = address(0);
        conditions.requiredTokenAmount = 0;
        conditions.isNFT = false;
        conditions.hasTokenRequirement = false;
        
        uint256 gateCount = _tokenAccess.getTokenGateCount(standardized);
        for (uint256 i = 0; i < gateCount; i++) {
            try _tokenAccess.getTokenGateDetails(standardized, i) returns (
                address tokenAddress, 
                uint256 threshold,
                uint256 tokenId,
                uint8 tokenType,
                string memory chainId,
                string memory tokenSymbol,
                string memory crossChainAddress
            ) {
                // 将每个门槛添加到数组中
                conditions.tokenRequirements.push(TokenRequirement({
                    tokenAddress: tokenAddress,
                    requiredAmount: threshold,
                    isNFT: (tokenType == 1 || tokenType == 2), // ERC721或ERC1155
                    tokenType: tokenType,
                    chainId: chainId,
                    symbol: tokenSymbol
                }));
            } catch {}
        }
        
        return conditions;
    }
    
    /**
     * @dev Check detailed membership status by domain name
     * @param user User address
     * @param domainName Domain name of the club
     * @return isPermanent Whether is a permanent member
     * @return isTemporary Whether is a temporary member
     * @return isTokenBased Whether is a token-based member
     */
    function checkDetailedMembership(address user, string memory domainName) external view returns (
        bool isPermanent,
        bool isTemporary,
        bool isTokenBased
    ) {
        if (!_isDomainValid(domainName)) {
            return (false, false, false);
        }
        
        string memory standardized = standardizeDomainName(domainName);
        
        // Check various membership qualifications
        isPermanent = checkPassCardMembership(standardized, user);
        
        try _tempMembership.hasActiveMembership(standardized, user) returns (bool result) {
            isTemporary = result;
        } catch {}
        
        try _tokenAccess.hasActiveMembership(standardized, user) returns (bool result) {
            isTokenBased = result;
        } catch {}
        
        return (isPermanent, isTemporary, isTokenBased);
    }
    
    /**
     * @dev Get membership card message signature data
     * @param user User address
     * @param domainName Domain name of the club
     * @return message Message string
     * @return signature Signature
     */
    function getMembershipMessage(address user, string memory domainName) external view returns (string memory message, bytes memory signature) {
        string memory standardized = standardizeDomainName(domainName);
        // This function will generate a membership card message and signature
        // This is just a placeholder implementation
        message = string(abi.encodePacked(
            "Web3Club Member: ", 
            standardized, 
            " - ", 
            _toAsciiString(user), 
            " at ", 
            _uint2str(block.timestamp)
        ));
        
        // Actual signature requires private key, this is not implemented
        signature = new bytes(0);
        
        return (message, signature);
    }
    
    /**
     * @dev Check if the domain is initialized
     */
    function isClubInitialized(string memory domainName) internal view returns (bool) {
        string memory standardized = standardizeDomainName(domainName);
        try _clubManager.isClubInitialized(standardized) returns (bool initialized) {
            return initialized;
        } catch {
            return false;
        }
    }
    
    /**
     * @dev Return whether the user is CURRENTLY an active member (considering expiration)
     */
    function hasActiveMembership(string memory domainName, address account) public view returns (bool) {
        string memory standardized = standardizeDomainName(domainName);
        if (!_isDomainValid(standardized)) return false;
        
        // First case: Through independent PASS card contract
        if (checkPassCardMembership(standardized, account)) {
            return true;
        }
        
        // Second case: Through temporary membership contract - MODIFIED
        try _tempMembership.isMembershipActive(standardized, account) returns (bool result) {
            if (result) return true;
        } catch {
            // Error handling: Continue to check other contracts  
        }
        
        // Third case: Through token access contract
        try _tokenAccess.hasActiveMembership(standardized, account) returns (bool result) {
            if (result) return true;
        } catch {
            // Error handling: Continue
        }
        
        return false;
    }
    
    /**
     * @dev Compatible with old version interface, keep consistent with hasActiveMembership
     */
    function hasActiveMembershipByDomain(string memory domainName, address account) external view returns (bool) {
        return hasActiveMembership(domainName, account);
    }
    
    // ===== Internal Helper Functions =====
    
    /**
     * @dev Check if the domain is valid
     */
    function _isDomainValid(string memory domainName) internal view returns (bool) {
        if (bytes(domainName).length == 0) return false;
        
        string memory standardized = standardizeDomainName(domainName);
        try _clubManager.isClubInitialized(standardized) returns (bool initialized) {
            return initialized;
        } catch {
            return false;
        }
    }
    
    /**
     * @dev Internal function to check membership status
     * @param user User address
     * @param domainName Domain name of the club
     * @return memberStatus Whether is a member that is CURRENTLY ACTIVE
     * @return expirationDate Expiration date (0 indicates permanent or token-based)
     * @return membershipType Membership type
     */
    function _checkMembership(address user, string memory domainName) internal view returns (bool memberStatus, uint256 expirationDate, string memory membershipType) {
        string memory standardized = standardizeDomainName(domainName);
        bool isPermanent = false;
        bool isTemporary = false;
        bool isTokenBased = false;
        uint256 expiry = 0;
        
        // Check PASS card membership qualification
        isPermanent = checkPassCardMembership(standardized, user);
        if (isPermanent) {
            membershipType = "permanent";
            return (true, 0, membershipType);
        }
        
        // Check temporary membership - MODIFIED
        try _tempMembership.isMembershipActive(standardized, user) returns (bool active) {
            // 使用isMembershipActive检查是否临时会员且在有效期内
            if (active) {
                try _tempMembership.getMembershipExpiry(standardized, user) returns (uint256 _expiry) {
                    expiry = _expiry;
                } catch {}
                membershipType = "temporary";
                return (true, expiry, membershipType);
            } else {
                // 如果不活跃但曾是会员，获取过期时间用于显示
                try _tempMembership.hasMembership(standardized, user) returns (bool wasMember) {
                    if (wasMember) {
                        try _tempMembership.getMembershipExpiry(standardized, user) returns (uint256 _expiry) {
                            expiry = _expiry;
                        } catch {}
                        membershipType = "temporary-expired";
                        return (false, expiry, membershipType); // 这里返回false表示不再活跃
                    }
                } catch {}
            }
        } catch {}
        
        // Check token holdings
        try _tokenAccess.hasActiveMembership(standardized, user) returns (bool result) {
            isTokenBased = result;
            if (isTokenBased) {
                membershipType = "token-based";
                return (true, 0, membershipType);
            }
        } catch {}
        
        return (false, 0, "");
    }
    
    /**
     * @dev Convert uint to string
     */
    function _uint2str(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) {
            return "0";
        }
        
        uint256 j = _i;
        uint256 length;
        
        while (j != 0) {
            length++;
            j /= 10;
        }
        
        bytes memory bstr = new bytes(length);
        uint256 k = length;
        j = _i;
        
        while (j != 0) {
            bstr[--k] = bytes1(uint8(48 + j % 10));
            j /= 10;
        }
        
        return string(bstr);
    }
    
    /**
     * @dev Convert address to ASCII string
     */
    function _toAsciiString(address x) internal pure returns (string memory) {
        bytes memory s = new bytes(40);
        for (uint i = 0; i < 20; i++) {
            bytes1 b = bytes1(uint8(uint(uint160(x)) / (2**(8*(19 - i)))));
            bytes1 hi = bytes1(uint8(b) / 16);
            bytes1 lo = bytes1(uint8(b) - 16 * uint8(hi));
            s[2*i] = _char(hi);
            s[2*i+1] = _char(lo);            
        }
        return string(abi.encodePacked("0x", s));
    }
    
    function _char(bytes1 b) internal pure returns (bytes1 c) {
        if (uint8(b) < 10) return bytes1(uint8(b) + 0x30);
        else return bytes1(uint8(b) + 0x57);
    }
} 