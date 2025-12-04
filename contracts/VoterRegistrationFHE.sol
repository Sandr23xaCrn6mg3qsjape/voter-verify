// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FHE, euint32, ebool } from "@fhevm/solidity/lib/FHE.sol";
import { SepoliaConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract VoterRegistrationFHE is SepoliaConfig {
    // FHE-backed structures
    struct EncryptedRegistration {
        uint256 id;
        euint32 encryptedNationalId;
        euint32 encryptedDOB;
        euint32 encryptedAddressHash;
        euint32 encryptedEligibilityFlags; // packed eligibility indicators
        uint256 timestamp;
    }

    struct DecryptedCredential {
        string anonCredential; // opaque string returned after decryption
        bool issued;
    }

    // Counters and storage
    uint256 public registrationCount;
    mapping(uint256 => EncryptedRegistration) public registrations;
    mapping(uint256 => DecryptedCredential) public credentials;

    // Track requests
    mapping(uint256 => uint256) private requestToRegistrationId;
    mapping(uint256 => uint256) private requestToCredentialId;

    // Track issued anonymous credentials to prevent double-issuance
    mapping(bytes32 => bool) public usedCredentialCommitments;

    // Events
    event RegistrationSubmitted(uint256 indexed regId, uint256 timestamp);
    event EligibilityVerificationRequested(uint256 indexed regId);
    event CredentialIssuanceRequested(uint256 indexed regId, uint256 credId);
    event EligibilityVerified(uint256 indexed regId);
    event CredentialIssued(uint256 indexed credId);

    // Placeholder access control modifier
    modifier onlyRegistrar() {
        // Access control should be implemented off-chain or via an admin role
        _;
    }

    /// @notice Submit encrypted voter registration
    function submitEncryptedRegistration(
        euint32 encryptedNationalId,
        euint32 encryptedDOB,
        euint32 encryptedAddressHash,
        euint32 encryptedEligibilityFlags
    ) public {
        registrationCount += 1;
        uint256 newId = registrationCount;

        registrations[newId] = EncryptedRegistration({
            id: newId,
            encryptedNationalId: encryptedNationalId,
            encryptedDOB: encryptedDOB,
            encryptedAddressHash: encryptedAddressHash,
            encryptedEligibilityFlags: encryptedEligibilityFlags,
            timestamp: block.timestamp
        });

        // initialize credential slot
        credentials[newId] = DecryptedCredential({
            anonCredential: "",
            issued: false
        });

        emit RegistrationSubmitted(newId, block.timestamp);
    }

    /// @notice Request FHE cross-database eligibility verification
    function requestEligibilityVerification(uint256 regId) public onlyRegistrar {
        EncryptedRegistration storage reg = registrations[regId];

        // collect ciphertexts
        bytes32;
        ciphertexts[0] = FHE.toBytes32(reg.encryptedNationalId);
        ciphertexts[1] = FHE.toBytes32(reg.encryptedDOB);
        ciphertexts[2] = FHE.toBytes32(reg.encryptedAddressHash);
        ciphertexts[3] = FHE.toBytes32(reg.encryptedEligibilityFlags);

        // request decryption/verification; callback will be eligibilityVerificationCallback
        uint256 reqId = FHE.requestDecryption(ciphertexts, this.eligibilityVerificationCallback.selector);
        requestToRegistrationId[reqId] = regId;

        emit EligibilityVerificationRequested(regId);
    }

    /// @notice Callback invoked with verification result (cleartexts contains verification outcomes)
    function eligibilityVerificationCallback(
        uint256 requestId,
        bytes memory cleartexts,
        bytes memory proof
    ) public {
        uint256 regId = requestToRegistrationId[requestId];
        require(regId != 0, "Invalid request id");

        // verify the proof produced by the FHE service
        FHE.checkSignatures(requestId, cleartexts, proof);

        // decode returned values: expect a single bool or flag array indicating eligibility
        bool isEligible = abi.decode(cleartexts, (bool));

        require(isEligible, "Not eligible");

        emit EligibilityVerified(regId);
    }

    /// @notice Request issuance of an anonymous voting credential (encrypted flow)
    function requestAnonymousCredential(uint256 regId, bytes32 credentialCommitment) public onlyRegistrar {
        require(!credentials[regId].issued, "Credential already issued");
        require(!usedCredentialCommitments[credentialCommitment], "Commitment already used");

        EncryptedRegistration storage reg = registrations[regId];

        // send minimal ciphertexts for issuance policy; the issuance service will produce an anon credential string
        bytes32;
        ciphertexts[0] = FHE.toBytes32(reg.encryptedNationalId);
        ciphertexts[1] = FHE.toBytes32(reg.encryptedEligibilityFlags);

        uint256 credId = regId; // reuse regId as credential id for simplicity
        uint256 reqId = FHE.requestDecryption(ciphertexts, this.credentialIssuanceCallback.selector);
        requestToCredentialId[reqId] = credId;

        // temporarily record the commitment to prevent races (will be finalized on issuance callback)
        usedCredentialCommitments[credentialCommitment] = true;

        emit CredentialIssuanceRequested(regId, credId);
    }

    /// @notice Callback for credential issuance; cleartexts contains the anonymized credential
    function credentialIssuanceCallback(
        uint256 requestId,
        bytes memory cleartexts,
        bytes memory proof
    ) public {
        uint256 credId = requestToCredentialId[requestId];
        require(credId != 0, "Invalid credential request");

        // verify proof
        FHE.checkSignatures(requestId, cleartexts, proof);

        // decode anonymized credential (opaque string)
        string[] memory outputs = abi.decode(cleartexts, (string[]));
        // outputs[0] is expected to be the anonymous credential
        string memory anonCred = outputs[0];

        DecryptedCredential storage dc = credentials[credId];
        require(!dc.issued, "Already issued");

        dc.anonCredential = anonCred;
        dc.issued = true;

        emit CredentialIssued(credId);
    }

    /// @notice Consume an anonymous credential commitment to prevent double-voting (called by ballot contract)
    function consumeCredentialCommitment(bytes32 commitment) public {
        require(!usedCredentialCommitments[commitment], "Already consumed");
        usedCredentialCommitments[commitment] = true;
    }

    /// @notice Get decrypted credential (opaque) for a registration
    function getCredential(uint256 regId) public view returns (string memory anonCredential, bool issued) {
        DecryptedCredential storage dc = credentials[regId];
        return (dc.anonCredential, dc.issued);
    }

    /// @notice Helper to check initialization state of an euint32
    function isEuintInitialized(euint32 x) public pure returns (bool) {
        return FHE.isInitialized(x);
    }
}
