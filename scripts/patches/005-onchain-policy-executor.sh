#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

readonly EXPECTED_ORIGIN_SLUG="prateushsharma/sentinel-fcc"
readonly PROTOCOL_BRANCH="feat/protocol-v1-foundation"
readonly DEVELOP_BRANCH="develop"
readonly FEATURE_BRANCH="feat/onchain-policy-executor"
readonly ARCHIVE_RELATIVE_PATH="scripts/patches/005-onchain-policy-executor.sh"

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"
SCRIPT_BASENAME="$(basename -- "$SCRIPT_PATH")"
PROJECT_ROOT="${1:-$(pwd)}"
PROJECT_ROOT="$(cd "$PROJECT_ROOT" && pwd)"
BASE_BRANCH=""

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

trap 'die "Patch failed at line $LINENO while running: $BASH_COMMAND"' ERR

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

normalize_github_slug() {
  local url="$1"
  url="${url%.git}"
  url="${url#git@github.com:}"
  url="${url#ssh://git@github.com/}"
  url="${url#https://github.com/}"
  url="${url#http://github.com/}"
  printf '%s' "$url"
}

validate_and_create_branch() {
  local current_branch origin_url origin_slug status_line current_sha remote_sha

  [[ -d "$PROJECT_ROOT/.git" ]] || die "Not a Git repository: $PROJECT_ROOT"

  current_branch="$(git -C "$PROJECT_ROOT" branch --show-current)"
  case "$current_branch" in
    "$PROTOCOL_BRANCH"|"$DEVELOP_BRANCH")
      BASE_BRANCH="$current_branch"
      ;;
    *)
      die "Run Patch 005 from '$PROTOCOL_BRANCH' or '$DEVELOP_BRANCH'; current branch is '$current_branch'."
      ;;
  esac

  origin_url="$(git -C "$PROJECT_ROOT" remote get-url origin 2>/dev/null || true)"
  origin_slug="$(normalize_github_slug "$origin_url")"
  [[ "$origin_slug" == "$EXPECTED_ORIGIN_SLUG" ]] ||
    die "Unexpected origin remote: $origin_url"

  git -C "$PROJECT_ROOT" fetch origin "$BASE_BRANCH" --prune
  current_sha="$(git -C "$PROJECT_ROOT" rev-parse HEAD)"
  remote_sha="$(git -C "$PROJECT_ROOT" rev-parse "origin/$BASE_BRANCH")"
  [[ "$current_sha" == "$remote_sha" ]] ||
    die "Local $BASE_BRANCH is not synchronized with origin/$BASE_BRANCH."

  while IFS= read -r status_line; do
    [[ -z "$status_line" ]] && continue
    if [[ "$(dirname -- "$SCRIPT_PATH")" == "$PROJECT_ROOT" && "$status_line" == "?? $SCRIPT_BASENAME" ]]; then
      continue
    fi
    printf '%s\n' "$status_line" >&2
    die "Working tree contains unrelated changes."
  done < <(git -C "$PROJECT_ROOT" status --porcelain=v1 --untracked-files=all)

  for required in \
    contracts/libraries/SentinelProtocol.sol \
    go/pkg/protocol/hashing.go \
    test/SentinelProtocol.t.sol \
    testdata/protocol/v1.json; do
    [[ -f "$PROJECT_ROOT/$required" ]] ||
      die "Protocol foundation is missing: $required"
  done

  if git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/heads/$FEATURE_BRANCH"; then
    die "Local branch already exists: $FEATURE_BRANCH"
  fi
  if git -C "$PROJECT_ROOT" ls-remote --exit-code --heads origin "$FEATURE_BRANCH" >/dev/null 2>&1; then
    die "Remote branch already exists: $FEATURE_BRANCH"
  fi

  git -C "$PROJECT_ROOT" switch -c "$FEATURE_BRANCH"
  ok "Created stacked feature branch: $FEATURE_BRANCH"
  info "Pull-request base will be: $BASE_BRANCH"
}

extend_protocol_version_accessors() {
  python3 - "$PROJECT_ROOT/contracts/libraries/SentinelProtocol.sol" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
anchor = """    function policyTypeHash() internal pure returns (bytes32) {
        return POLICY_TYPEHASH;
    }

"""
addition = """    function currentProtocolVersion() internal pure returns (uint16) {
        return CURRENT_PROTOCOL_VERSION;
    }

    function currentPolicySchemaVersion() internal pure returns (uint16) {
        return CURRENT_POLICY_SCHEMA_VERSION;
    }

    function currentDecisionVersion() internal pure returns (uint16) {
        return CURRENT_DECISION_VERSION;
    }

"""

if addition not in text:
    if anchor not in text:
        raise SystemExit("SentinelProtocol policyTypeHash anchor was not found")
    text = text.replace(anchor, addition + anchor, 1)

path.write_text(text, encoding="utf-8")
PY
}

write_interfaces() {
  mkdir -p "$PROJECT_ROOT/contracts/interfaces"

  cat > "$PROJECT_ROOT/contracts/interfaces/ISentinelDecisionVerifier.sol" <<'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title ISentinelDecisionVerifier
/// @notice Verifies an already domain-separated Sentinel decision digest.
interface ISentinelDecisionVerifier {
    /// @param decisionDigest EIP-712 digest scoped to one executor deployment.
    /// @param proof Verifier-specific proof, signature, or attestation bytes.
    function verifyDecision(bytes32 decisionDigest, bytes calldata proof) external view returns (bool);
}
EOF

  cat > "$PROJECT_ROOT/contracts/interfaces/ISentinelPolicyRegistry.sol" <<'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title ISentinelPolicyRegistry
/// @notice Public commitment registry for private Sentinel policy versions.
interface ISentinelPolicyRegistry {
    struct PolicyRecord {
        address owner;
        address account;
        bytes32 commitment;
        uint64 version;
        uint64 validAfter;
        uint64 validUntil;
        bool active;
    }

    function getPolicy(bytes32 policyId) external view returns (PolicyRecord memory);

    function isPolicyActive(
        bytes32 policyId,
        bytes32 commitment,
        address account,
        uint64 version,
        uint256 timestamp
    ) external view returns (bool);
}
EOF
}

write_policy_registry() {
  cat > "$PROJECT_ROOT/contracts/SentinelPolicyRegistry.sol" <<'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ISentinelPolicyRegistry} from "./interfaces/ISentinelPolicyRegistry.sol";
import {SentinelProtocol} from "./libraries/SentinelProtocol.sol";

/// @title SentinelPolicyRegistry
/// @notice Stores public commitments and lifecycle state for private policies.
/// @dev Policy rule contents remain offchain/confidential; only commitments live here.
contract SentinelPolicyRegistry is ISentinelPolicyRegistry {
    error InvalidPolicyId();
    error InvalidPolicyOwner();
    error InvalidPolicyAccount();
    error InvalidPolicyVersion();
    error InvalidValidityWindow();
    error UnsupportedProtocolVersion(uint16 supplied);
    error UnsupportedPolicySchemaVersion(uint16 supplied);
    error PolicyAlreadyExists(bytes32 policyId);
    error PolicyNotFound(bytes32 policyId);
    error PolicyNotActive(bytes32 policyId);
    error UnauthorizedPolicyOwner(address caller);
    error PolicyIdentityChanged();
    error PolicyVersionNotSequential(uint64 expected, uint64 supplied);
    error PolicyVersionExhausted();

    event PolicyRegistered(
        bytes32 indexed policyId,
        address indexed owner,
        address indexed account,
        uint64 version,
        bytes32 commitment,
        uint64 validAfter,
        uint64 validUntil
    );

    event PolicyUpdated(
        bytes32 indexed policyId,
        uint64 previousVersion,
        uint64 newVersion,
        bytes32 previousCommitment,
        bytes32 newCommitment,
        uint64 validAfter,
        uint64 validUntil
    );

    event PolicyRevoked(bytes32 indexed policyId, uint64 indexed version, address indexed owner);

    mapping(bytes32 policyId => PolicyRecord record) private _policies;

    function registerPolicy(SentinelProtocol.PolicyEnvelope calldata policy)
        external
        returns (bytes32 commitment)
    {
        _validatePolicyEnvelope(policy);

        if (policy.owner != msg.sender) {
            revert UnauthorizedPolicyOwner(msg.sender);
        }
        if (_policies[policy.policyId].owner != address(0)) {
            revert PolicyAlreadyExists(policy.policyId);
        }

        commitment = SentinelProtocol.hashPolicyEnvelope(policy);
        _policies[policy.policyId] = PolicyRecord({
            owner: policy.owner,
            account: policy.account,
            commitment: commitment,
            version: policy.policyVersion,
            validAfter: policy.validAfter,
            validUntil: policy.validUntil,
            active: true
        });

        emit PolicyRegistered(
            policy.policyId,
            policy.owner,
            policy.account,
            policy.policyVersion,
            commitment,
            policy.validAfter,
            policy.validUntil
        );
    }

    function updatePolicy(SentinelProtocol.PolicyEnvelope calldata policy)
        external
        returns (bytes32 commitment)
    {
        PolicyRecord storage existing = _policies[policy.policyId];

        if (existing.owner == address(0)) {
            revert PolicyNotFound(policy.policyId);
        }
        if (!existing.active) {
            revert PolicyNotActive(policy.policyId);
        }
        if (msg.sender != existing.owner) {
            revert UnauthorizedPolicyOwner(msg.sender);
        }

        _validatePolicyEnvelope(policy);

        if (policy.owner != existing.owner || policy.account != existing.account) {
            revert PolicyIdentityChanged();
        }
        if (existing.version == type(uint64).max) {
            revert PolicyVersionExhausted();
        }

        uint64 expectedVersion = existing.version + 1;
        if (policy.policyVersion != expectedVersion) {
            revert PolicyVersionNotSequential(expectedVersion, policy.policyVersion);
        }

        uint64 previousVersion = existing.version;
        bytes32 previousCommitment = existing.commitment;
        commitment = SentinelProtocol.hashPolicyEnvelope(policy);

        existing.commitment = commitment;
        existing.version = policy.policyVersion;
        existing.validAfter = policy.validAfter;
        existing.validUntil = policy.validUntil;

        emit PolicyUpdated(
            policy.policyId,
            previousVersion,
            policy.policyVersion,
            previousCommitment,
            commitment,
            policy.validAfter,
            policy.validUntil
        );
    }

    function revokePolicy(bytes32 policyId) external {
        PolicyRecord storage existing = _policies[policyId];

        if (existing.owner == address(0)) {
            revert PolicyNotFound(policyId);
        }
        if (!existing.active) {
            revert PolicyNotActive(policyId);
        }
        if (msg.sender != existing.owner) {
            revert UnauthorizedPolicyOwner(msg.sender);
        }

        existing.active = false;
        emit PolicyRevoked(policyId, existing.version, existing.owner);
    }

    function getPolicy(bytes32 policyId) external view returns (PolicyRecord memory) {
        return _policies[policyId];
    }

    function isPolicyActive(
        bytes32 policyId,
        bytes32 commitment,
        address account,
        uint64 version,
        uint256 timestamp
    ) external view returns (bool) {
        PolicyRecord storage policy = _policies[policyId];

        return policy.active && policy.owner != address(0) && policy.commitment == commitment
            && policy.account == account && policy.version == version && timestamp >= policy.validAfter
            && timestamp <= policy.validUntil;
    }

    function _validatePolicyEnvelope(SentinelProtocol.PolicyEnvelope calldata policy)
        private
        pure
    {
        if (policy.protocolVersion != SentinelProtocol.currentProtocolVersion()) {
            revert UnsupportedProtocolVersion(policy.protocolVersion);
        }
        if (policy.schemaVersion != SentinelProtocol.currentPolicySchemaVersion()) {
            revert UnsupportedPolicySchemaVersion(policy.schemaVersion);
        }
        if (policy.policyId == bytes32(0)) {
            revert InvalidPolicyId();
        }
        if (policy.owner == address(0)) {
            revert InvalidPolicyOwner();
        }
        if (policy.account == address(0)) {
            revert InvalidPolicyAccount();
        }
        if (policy.policyVersion == 0) {
            revert InvalidPolicyVersion();
        }
        if (policy.validUntil == 0 || policy.validAfter > policy.validUntil) {
            revert InvalidValidityWindow();
        }
        if (
            policy.chainScopeHash == bytes32(0) || policy.rulesHash == bytes32(0)
                || policy.metadataHash == bytes32(0)
        ) {
            revert InvalidPolicyId();
        }
    }
}
EOF
}

write_decision_verifier() {
  cat > "$PROJECT_ROOT/contracts/SentinelECDSADecisionVerifier.sol" <<'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ISentinelDecisionVerifier} from "./interfaces/ISentinelDecisionVerifier.sol";

/// @title SentinelECDSADecisionVerifier
/// @notice Strict immutable-signer verifier for domain-separated decision digests.
/// @dev The signer may be a TEE-controlled secp256k1 key. FCC-native attestation
///      verification can implement ISentinelDecisionVerifier without changing the executor.
contract SentinelECDSADecisionVerifier is ISentinelDecisionVerifier {
    // secp256k1n / 2, enforcing EIP-2 low-s signatures.
    uint256 private constant _MAX_VALID_S =
        0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

    address public immutable signer;

    error InvalidSigner();

    constructor(address signer_) {
        if (signer_ == address(0)) {
            revert InvalidSigner();
        }
        signer = signer_;
    }

    function verifyDecision(bytes32 decisionDigest, bytes calldata proof)
        external
        view
        returns (bool)
    {
        if (proof.length != 65) {
            return false;
        }

        bytes32 r;
        bytes32 s;
        uint8 v;

        assembly ("memory-safe") {
            r := calldataload(proof.offset)
            s := calldataload(add(proof.offset, 32))
            v := byte(0, calldataload(add(proof.offset, 64)))
        }

        if (uint256(s) > _MAX_VALID_S || (v != 27 && v != 28)) {
            return false;
        }

        address recovered = ecrecover(decisionDigest, v, r, s);
        return recovered != address(0) && recovered == signer;
    }
}
EOF
}

write_executor() {
  cat > "$PROJECT_ROOT/contracts/SentinelExecutor.sol" <<'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ISentinelDecisionVerifier} from "./interfaces/ISentinelDecisionVerifier.sol";
import {ISentinelPolicyRegistry} from "./interfaces/ISentinelPolicyRegistry.sol";
import {SentinelProtocol} from "./libraries/SentinelProtocol.sol";

/// @title SentinelExecutor
/// @notice Replay-safe smart-account boundary for exact TEE-authorized calls.
contract SentinelExecutor {
    error InvalidRegistry();
    error InvalidVerifier();
    error InvalidSimulationWindow(uint64 supplied);
    error ReentrantExecution();
    error UnsupportedProtocolVersion(uint16 supplied);
    error UnsupportedDecisionVersion(uint16 supplied);
    error InvalidChainId();
    error InvalidExecutor();
    error InvalidAccount();
    error InvalidAgent();
    error InvalidTarget();
    error InvalidValidityWindow();
    error IntentNotCurrentlyValid();
    error DecisionNotCurrentlyValid();
    error DecisionNotApproved();
    error InvalidRiskScore(uint8 supplied);
    error IntentHashMismatch();
    error DecisionBindingMismatch();
    error PolicyInactive();
    error SimulationBlockNotHistorical(uint64 simulationBlock, uint256 currentBlock);
    error SimulationBlockStale(uint256 age, uint64 maximumAge);
    error SimulationBlockHashMismatch();
    error InvalidDecisionProof();
    error RequestAlreadyConsumed(bytes32 requestId);
    error DecisionAlreadyConsumed(bytes32 decisionHash);
    error UnexpectedNonce(address agent, uint64 expected, uint64 supplied);
    error NonceExhausted(address agent);

    event ExecutionAuthorized(
        bytes32 indexed requestId,
        bytes32 indexed decisionHash,
        bytes32 indexed intentHash,
        bytes32 policyId,
        address agent,
        address target,
        uint64 nonce
    );

    event ExecutionCompleted(
        bytes32 indexed requestId,
        bytes32 indexed decisionHash,
        address indexed target,
        uint256 value,
        bytes32 returnDataHash
    );

    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant _NAME_HASH = keccak256("SentinelFCC");
    bytes32 private constant _VERSION_HASH = keccak256("1");

    ISentinelPolicyRegistry public immutable policyRegistry;
    ISentinelDecisionVerifier public immutable decisionVerifier;
    uint64 public immutable maxSimulationBlockAge;

    mapping(address agent => uint64 nonce) public nextNonce;
    mapping(bytes32 requestId => bool consumed) public consumedRequestIds;
    mapping(bytes32 decisionHash => bool consumed) public consumedDecisionHashes;

    uint256 private _executionLock = 1;

    constructor(
        ISentinelPolicyRegistry policyRegistry_,
        ISentinelDecisionVerifier decisionVerifier_,
        uint64 maxSimulationBlockAge_
    ) {
        if (address(policyRegistry_) == address(0) || address(policyRegistry_).code.length == 0) {
            revert InvalidRegistry();
        }
        if (address(decisionVerifier_) == address(0) || address(decisionVerifier_).code.length == 0) {
            revert InvalidVerifier();
        }
        if (maxSimulationBlockAge_ == 0 || maxSimulationBlockAge_ > 255) {
            revert InvalidSimulationWindow(maxSimulationBlockAge_);
        }

        policyRegistry = policyRegistry_;
        decisionVerifier = decisionVerifier_;
        maxSimulationBlockAge = maxSimulationBlockAge_;
    }

    receive() external payable {}

    modifier nonReentrant() {
        if (_executionLock != 1) {
            revert ReentrantExecution();
        }
        _executionLock = 2;
        _;
        _executionLock = 1;
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                _EIP712_DOMAIN_TYPEHASH,
                _NAME_HASH,
                _VERSION_HASH,
                block.chainid,
                address(this)
            )
        );
    }

    function decisionDigest(SentinelProtocol.FirewallDecision memory decision)
        public
        view
        returns (bytes32)
    {
        bytes32 decisionHash = SentinelProtocol.hashFirewallDecision(decision);
        return keccak256(abi.encodePacked(hex"1901", domainSeparator(), decisionHash));
    }

    function execute(
        SentinelProtocol.TransactionIntent calldata intent,
        SentinelProtocol.FirewallDecision calldata decision,
        bytes calldata proof
    ) external nonReentrant returns (bytes memory returnData) {
        bytes32 intentHash = SentinelProtocol.hashTransactionIntent(intent);

        _validateIntent(intent);
        _validateDecisionBinding(intent, decision, intentHash);
        _validatePolicy(decision);
        _validateSimulation(decision);

        bytes32 decisionHash = SentinelProtocol.hashFirewallDecision(decision);
        _validateReplayState(decision, decisionHash, intent.nonce);

        bytes32 digest = keccak256(abi.encodePacked(hex"1901", domainSeparator(), decisionHash));
        if (!decisionVerifier.verifyDecision(digest, proof)) {
            revert InvalidDecisionProof();
        }

        _consumeReplayState(decision, decisionHash, intent.nonce);

        emit ExecutionAuthorized(
            decision.requestId,
            decisionHash,
            intentHash,
            decision.policyId,
            intent.agent,
            intent.target,
            intent.nonce
        );

        bool success;
        (success, returnData) = intent.target.call{value: intent.value}(intent.data);
        if (!success) {
            _revertWithReturnData(returnData);
        }

        emit ExecutionCompleted(
            decision.requestId,
            decisionHash,
            intent.target,
            intent.value,
            keccak256(returnData)
        );
    }

    function _validateIntent(SentinelProtocol.TransactionIntent calldata intent) private view {
        if (intent.protocolVersion != SentinelProtocol.currentProtocolVersion()) {
            revert UnsupportedProtocolVersion(intent.protocolVersion);
        }
        if (intent.chainId != block.chainid) {
            revert InvalidChainId();
        }
        if (intent.executor != address(this)) {
            revert InvalidExecutor();
        }
        if (intent.account != address(this)) {
            revert InvalidAccount();
        }
        if (intent.agent == address(0)) {
            revert InvalidAgent();
        }
        if (intent.target == address(0)) {
            revert InvalidTarget();
        }
        if (intent.validUntil == 0 || intent.validAfter > intent.validUntil) {
            revert InvalidValidityWindow();
        }
        if (block.timestamp < intent.validAfter || block.timestamp > intent.validUntil) {
            revert IntentNotCurrentlyValid();
        }
    }

    function _validateDecisionBinding(
        SentinelProtocol.TransactionIntent calldata intent,
        SentinelProtocol.FirewallDecision calldata decision,
        bytes32 intentHash
    ) private view {
        if (decision.protocolVersion != SentinelProtocol.currentProtocolVersion()) {
            revert UnsupportedProtocolVersion(decision.protocolVersion);
        }
        if (decision.decisionVersion != SentinelProtocol.currentDecisionVersion()) {
            revert UnsupportedDecisionVersion(decision.decisionVersion);
        }
        if (!decision.approved) {
            revert DecisionNotApproved();
        }
        if (decision.riskScore > 100) {
            revert InvalidRiskScore(decision.riskScore);
        }
        if (decision.requestId == bytes32(0) || decision.policyId == bytes32(0)) {
            revert DecisionBindingMismatch();
        }
        if (decision.intentHash != intentHash) {
            revert IntentHashMismatch();
        }
        if (decision.chainId != intent.chainId || decision.executor != intent.executor) {
            revert DecisionBindingMismatch();
        }
        if (
            decision.account != intent.account || decision.agent != intent.agent
                || decision.nonce != intent.nonce
        ) {
            revert DecisionBindingMismatch();
        }
        if (
            decision.validAfter != intent.validAfter || decision.validUntil != intent.validUntil
                || decision.validUntil == 0 || decision.validAfter > decision.validUntil
        ) {
            revert DecisionBindingMismatch();
        }
        if (block.timestamp < decision.validAfter || block.timestamp > decision.validUntil) {
            revert DecisionNotCurrentlyValid();
        }
    }

    function _validatePolicy(SentinelProtocol.FirewallDecision calldata decision) private view {
        bool active = policyRegistry.isPolicyActive(
            decision.policyId,
            decision.policyCommitment,
            address(this),
            decision.policyVersion,
            block.timestamp
        );
        if (!active) {
            revert PolicyInactive();
        }
    }

    function _validateSimulation(SentinelProtocol.FirewallDecision calldata decision) private view {
        uint256 simulationBlock = decision.simulationBlockNumber;
        if (simulationBlock >= block.number) {
            revert SimulationBlockNotHistorical(decision.simulationBlockNumber, block.number);
        }

        uint256 age = block.number - simulationBlock;
        if (age > maxSimulationBlockAge) {
            revert SimulationBlockStale(age, maxSimulationBlockAge);
        }

        bytes32 canonicalBlockHash = blockhash(simulationBlock);
        if (
            canonicalBlockHash == bytes32(0)
                || canonicalBlockHash != decision.simulationBlockHash
        ) {
            revert SimulationBlockHashMismatch();
        }
    }

    function _validateReplayState(
        SentinelProtocol.FirewallDecision calldata decision,
        bytes32 decisionHash,
        uint64 suppliedNonce
    ) private view {
        if (consumedRequestIds[decision.requestId]) {
            revert RequestAlreadyConsumed(decision.requestId);
        }
        if (consumedDecisionHashes[decisionHash]) {
            revert DecisionAlreadyConsumed(decisionHash);
        }

        uint64 expectedNonce = nextNonce[decision.agent];
        if (suppliedNonce != expectedNonce) {
            revert UnexpectedNonce(decision.agent, expectedNonce, suppliedNonce);
        }
        if (expectedNonce == type(uint64).max) {
            revert NonceExhausted(decision.agent);
        }
    }

    function _consumeReplayState(
        SentinelProtocol.FirewallDecision calldata decision,
        bytes32 decisionHash,
        uint64 nonce
    ) private {
        consumedRequestIds[decision.requestId] = true;
        consumedDecisionHashes[decisionHash] = true;
        nextNonce[decision.agent] = nonce + 1;
    }

    function _revertWithReturnData(bytes memory returnData) private pure {
        assembly ("memory-safe") {
            revert(add(returnData, 32), mload(returnData))
        }
    }
}
EOF
}

write_contract_tests() {
  cat > "$PROJECT_ROOT/test/SentinelPolicyRegistry.t.sol" <<'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {SentinelPolicyRegistry} from "../contracts/SentinelPolicyRegistry.sol";
import {ISentinelPolicyRegistry} from "../contracts/interfaces/ISentinelPolicyRegistry.sol";
import {SentinelProtocol} from "../contracts/libraries/SentinelProtocol.sol";

interface VmPolicyRegistry {
    function prank(address sender) external;
    function expectRevert(bytes4 revertData) external;
}

contract SentinelPolicyRegistryTest {
    VmPolicyRegistry private constant vm =
        VmPolicyRegistry(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant OWNER = address(0xA11CE);
    address private constant ACCOUNT = address(0xBEEF);
    bytes32 private constant POLICY_ID = keccak256("sentinel-policy-registry-test");

    SentinelPolicyRegistry private registry;

    function setUp() public {
        registry = new SentinelPolicyRegistry();
    }

    function testOwnerRegistersPolicyCommitment() public {
        SentinelProtocol.PolicyEnvelope memory policy = _policy(1);

        vm.prank(OWNER);
        bytes32 commitment = registry.registerPolicy(policy);

        require(commitment == SentinelProtocol.hashPolicyEnvelope(policy), "commitment mismatch");

        ISentinelPolicyRegistry.PolicyRecord memory stored = registry.getPolicy(POLICY_ID);
        require(stored.owner == OWNER, "owner mismatch");
        require(stored.account == ACCOUNT, "account mismatch");
        require(stored.commitment == commitment, "stored commitment mismatch");
        require(stored.version == 1, "version mismatch");
        require(stored.active, "policy inactive");
    }

    function testNonOwnerCannotRegisterPolicy() public {
        SentinelProtocol.PolicyEnvelope memory policy = _policy(1);

        vm.expectRevert(SentinelPolicyRegistry.UnauthorizedPolicyOwner.selector);
        registry.registerPolicy(policy);
    }

    function testUpdateRequiresSequentialVersion() public {
        SentinelProtocol.PolicyEnvelope memory policy = _policy(1);
        vm.prank(OWNER);
        registry.registerPolicy(policy);

        SentinelProtocol.PolicyEnvelope memory invalidUpdate = _policy(3);
        vm.prank(OWNER);
        vm.expectRevert(SentinelPolicyRegistry.PolicyVersionNotSequential.selector);
        registry.updatePolicy(invalidUpdate);

        SentinelProtocol.PolicyEnvelope memory validUpdate = _policy(2);
        validUpdate.rulesHash = keccak256("updated-rules");
        vm.prank(OWNER);
        bytes32 updatedCommitment = registry.updatePolicy(validUpdate);

        ISentinelPolicyRegistry.PolicyRecord memory stored = registry.getPolicy(POLICY_ID);
        require(stored.version == 2, "version not updated");
        require(stored.commitment == updatedCommitment, "commitment not updated");
    }

    function testRevokedPolicyIsInactive() public {
        SentinelProtocol.PolicyEnvelope memory policy = _policy(1);
        vm.prank(OWNER);
        bytes32 commitment = registry.registerPolicy(policy);

        vm.prank(OWNER);
        registry.revokePolicy(POLICY_ID);

        bool active = registry.isPolicyActive(
            POLICY_ID,
            commitment,
            ACCOUNT,
            1,
            policy.validAfter
        );
        require(!active, "revoked policy remains active");
    }

    function _policy(uint64 version)
        private
        pure
        returns (SentinelProtocol.PolicyEnvelope memory policy)
    {
        policy.protocolVersion = 1;
        policy.schemaVersion = 1;
        policy.policyId = POLICY_ID;
        policy.owner = OWNER;
        policy.account = ACCOUNT;
        policy.policyVersion = version;
        policy.validAfter = 1_900_000_000;
        policy.validUntil = 2_100_000_000;
        policy.chainScopeHash = keccak256("chain-scope");
        policy.rulesHash = keccak256("rules");
        policy.metadataHash = keccak256("metadata");
    }
}
EOF

  cat > "$PROJECT_ROOT/test/SentinelECDSADecisionVerifier.t.sol" <<'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {SentinelECDSADecisionVerifier} from "../contracts/SentinelECDSADecisionVerifier.sol";

interface VmECDSA {
    function addr(uint256 privateKey) external returns (address);
    function sign(uint256 privateKey, bytes32 digest)
        external
        returns (uint8 v, bytes32 r, bytes32 s);
}

contract SentinelECDSADecisionVerifierTest {
    VmECDSA private constant vm =
        VmECDSA(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 private constant SIGNER_KEY = 0xA11CE;

    function testValidSignatureAccepted() public {
        address signer = vm.addr(SIGNER_KEY);
        SentinelECDSADecisionVerifier verifier = new SentinelECDSADecisionVerifier(signer);
        bytes32 digest = keccak256("sentinel-decision-digest");

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, digest);
        bytes memory proof = abi.encodePacked(r, s, v);

        require(verifier.verifyDecision(digest, proof), "valid signature rejected");
    }

    function testWrongDigestAndMalformedProofRejected() public {
        address signer = vm.addr(SIGNER_KEY);
        SentinelECDSADecisionVerifier verifier = new SentinelECDSADecisionVerifier(signer);
        bytes32 digest = keccak256("sentinel-decision-digest");

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, digest);
        bytes memory proof = abi.encodePacked(r, s, v);

        require(!verifier.verifyDecision(keccak256("wrong"), proof), "wrong digest accepted");
        require(!verifier.verifyDecision(digest, hex"1234"), "malformed proof accepted");
    }
}
EOF

  cat > "$PROJECT_ROOT/test/SentinelExecutor.t.sol" <<'EOF'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {SentinelExecutor} from "../contracts/SentinelExecutor.sol";
import {SentinelPolicyRegistry} from "../contracts/SentinelPolicyRegistry.sol";
import {ISentinelDecisionVerifier} from "../contracts/interfaces/ISentinelDecisionVerifier.sol";
import {SentinelProtocol} from "../contracts/libraries/SentinelProtocol.sol";

interface VmExecutor {
    function warp(uint256 timestamp) external;
    function roll(uint256 blockNumber) external;
    function setBlockhash(uint256 blockNumber, bytes32 blockHash) external;
    function prank(address sender) external;
    function expectRevert(bytes4 revertData) external;
    function deal(address account, uint256 balance) external;
}

contract MockDecisionVerifier is ISentinelDecisionVerifier {
    bool public result = true;

    function setResult(bool result_) external {
        result = result_;
    }

    function verifyDecision(bytes32, bytes calldata) external view returns (bool) {
        return result;
    }
}

contract SentinelExecutionTarget {
    error TargetFailure();

    uint256 public value;

    function setValue(uint256 value_) external payable returns (uint256) {
        value = value_;
        return value_ + 1;
    }

    function fail() external pure {
        revert TargetFailure();
    }
}

contract SentinelExecutorTest {
    VmExecutor private constant vm =
        VmExecutor(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint64 private constant NOW = 2_000_000_000;
    uint64 private constant SIMULATION_BLOCK = 999;
    bytes32 private constant SIMULATION_BLOCK_HASH = keccak256("simulation-block");
    bytes32 private constant POLICY_ID = keccak256("executor-policy");

    address private constant OWNER = address(0xA11CE);
    address private constant AGENT = address(0xA6E17);

    SentinelPolicyRegistry private registry;
    MockDecisionVerifier private verifier;
    SentinelExecutor private executor;
    SentinelExecutionTarget private target;
    bytes32 private policyCommitment;

    function setUp() public {
        vm.warp(NOW);
        vm.roll(1_000);
        vm.setBlockhash(SIMULATION_BLOCK, SIMULATION_BLOCK_HASH);

        registry = new SentinelPolicyRegistry();
        verifier = new MockDecisionVerifier();
        executor = new SentinelExecutor(registry, verifier, 64);
        target = new SentinelExecutionTarget();

        SentinelProtocol.PolicyEnvelope memory policy = _policy();
        vm.prank(OWNER);
        policyCommitment = registry.registerPolicy(policy);

        vm.deal(address(executor), 10 ether);
    }

    function testExecutesExactAuthorizedIntent() public {
        SentinelProtocol.TransactionIntent memory intent = _intent(0);
        SentinelProtocol.FirewallDecision memory decision = _decision(intent, keccak256("request-1"));

        bytes memory returnData = executor.execute(intent, decision, hex"01");

        require(target.value() == 77, "target state not updated");
        require(abi.decode(returnData, (uint256)) == 78, "return data mismatch");
        require(executor.nextNonce(AGENT) == 1, "nonce not consumed");
        require(executor.consumedRequestIds(decision.requestId), "request not consumed");
    }

    function testRequestCannotReplay() public {
        SentinelProtocol.TransactionIntent memory intent = _intent(0);
        SentinelProtocol.FirewallDecision memory decision = _decision(intent, keccak256("request-2"));

        executor.execute(intent, decision, hex"01");

        vm.expectRevert(SentinelExecutor.RequestAlreadyConsumed.selector);
        executor.execute(intent, decision, hex"01");
    }

    function testUnexpectedNonceRejected() public {
        SentinelProtocol.TransactionIntent memory intent = _intent(3);
        SentinelProtocol.FirewallDecision memory decision = _decision(intent, keccak256("request-3"));

        vm.expectRevert(SentinelExecutor.UnexpectedNonce.selector);
        executor.execute(intent, decision, hex"01");
    }

    function testIntentMutationBreaksDecisionBinding() public {
        SentinelProtocol.TransactionIntent memory intent = _intent(0);
        SentinelProtocol.FirewallDecision memory decision = _decision(intent, keccak256("request-4"));
        intent.data = abi.encodeWithSelector(target.setValue.selector, 999);

        vm.expectRevert(SentinelExecutor.IntentHashMismatch.selector);
        executor.execute(intent, decision, hex"01");
    }

    function testStaleSimulationRejected() public {
        SentinelProtocol.TransactionIntent memory intent = _intent(0);
        SentinelProtocol.FirewallDecision memory decision = _decision(intent, keccak256("request-5"));

        vm.roll(1_100);
        vm.expectRevert(SentinelExecutor.SimulationBlockStale.selector);
        executor.execute(intent, decision, hex"01");
    }

    function testInvalidProofRejected() public {
        SentinelProtocol.TransactionIntent memory intent = _intent(0);
        SentinelProtocol.FirewallDecision memory decision = _decision(intent, keccak256("request-6"));
        verifier.setResult(false);

        vm.expectRevert(SentinelExecutor.InvalidDecisionProof.selector);
        executor.execute(intent, decision, hex"01");
    }

    function testRevokedPolicyRejected() public {
        SentinelProtocol.TransactionIntent memory intent = _intent(0);
        SentinelProtocol.FirewallDecision memory decision = _decision(intent, keccak256("request-7"));

        vm.prank(OWNER);
        registry.revokePolicy(POLICY_ID);

        vm.expectRevert(SentinelExecutor.PolicyInactive.selector);
        executor.execute(intent, decision, hex"01");
    }

    function testTargetRevertDoesNotConsumeReplayState() public {
        SentinelProtocol.TransactionIntent memory intent = _intent(0);
        intent.data = abi.encodeWithSelector(target.fail.selector);
        SentinelProtocol.FirewallDecision memory decision = _decision(intent, keccak256("request-8"));

        vm.expectRevert(SentinelExecutionTarget.TargetFailure.selector);
        executor.execute(intent, decision, hex"01");

        require(executor.nextNonce(AGENT) == 0, "nonce consumed after reverted target");
        require(!executor.consumedRequestIds(decision.requestId), "request consumed after revert");
    }

    function _policy()
        private
        view
        returns (SentinelProtocol.PolicyEnvelope memory policy)
    {
        policy.protocolVersion = 1;
        policy.schemaVersion = 1;
        policy.policyId = POLICY_ID;
        policy.owner = OWNER;
        policy.account = address(executor);
        policy.policyVersion = 1;
        policy.validAfter = NOW - 100;
        policy.validUntil = NOW + 10_000;
        policy.chainScopeHash = keccak256(abi.encode(block.chainid));
        policy.rulesHash = keccak256("executor-rules");
        policy.metadataHash = keccak256("executor-metadata");
    }

    function _intent(uint64 nonce)
        private
        view
        returns (SentinelProtocol.TransactionIntent memory intent)
    {
        intent.protocolVersion = 1;
        intent.chainId = block.chainid;
        intent.executor = address(executor);
        intent.account = address(executor);
        intent.agent = AGENT;
        intent.target = address(target);
        intent.value = 0;
        intent.data = abi.encodeWithSelector(target.setValue.selector, 77);
        intent.nonce = nonce;
        intent.validAfter = NOW - 10;
        intent.validUntil = NOW + 1_000;
    }

    function _decision(
        SentinelProtocol.TransactionIntent memory intent,
        bytes32 requestId
    ) private view returns (SentinelProtocol.FirewallDecision memory decision) {
        decision.protocolVersion = 1;
        decision.decisionVersion = 1;
        decision.requestId = requestId;
        decision.intentHash = SentinelProtocol.hashTransactionIntent(intent);
        decision.policyId = POLICY_ID;
        decision.policyCommitment = policyCommitment;
        decision.policyVersion = 1;
        decision.chainId = intent.chainId;
        decision.executor = intent.executor;
        decision.account = intent.account;
        decision.agent = intent.agent;
        decision.nonce = intent.nonce;
        decision.validAfter = intent.validAfter;
        decision.validUntil = intent.validUntil;
        decision.simulationBlockNumber = SIMULATION_BLOCK;
        decision.simulationBlockHash = SIMULATION_BLOCK_HASH;
        decision.simulationHash = keccak256("normalized-effects");
        decision.approved = true;
        decision.riskScore = 12;
        decision.riskFlags = 0;
    }
}
EOF
}

write_documentation() {
  cat > "$PROJECT_ROOT/docs/onchain-enforcement.md" <<'EOF'
# Onchain Policy and Execution Boundary

## Components

### `SentinelPolicyRegistry`

The registry stores only public commitments and lifecycle metadata:

- immutable policy ID;
- immutable owner and protected account identity;
- current commitment and strictly increasing version;
- validity window;
- active or revoked state.

Private policy rules are never published. Updating a policy requires the current
owner and exactly the next version. Revocation is terminal for that policy ID.

### `SentinelExecutor`

Each executor is a smart-account boundary. A call executes only when all of the
following hold:

1. the intent targets the current chain and executor;
2. the protected account is the executor itself;
3. the intent and decision validity windows are active;
4. the decision binds the exact intent hash and execution fields;
5. the policy commitment/version is currently active;
6. the simulation block is historical, recent, and has the canonical block hash;
7. the verifier accepts the EIP-712 decision digest;
8. the request ID and decision hash have not been consumed;
9. the agent supplies its exact next nonce.

Replay state is written before the target call. If the target reverts, the whole
transaction—including replay-state writes—reverts atomically.

## Domain separation

The executor computes:

```text
keccak256(
  0x1901 ||
  EIP712Domain(
    name = "SentinelFCC",
    version = "1",
    chainId = block.chainid,
    verifyingContract = executor
  ) ||
  SentinelFirewallDecision struct hash
)
```

A proof issued for one chain or executor cannot be replayed against another.

## Verifier abstraction

`ISentinelDecisionVerifier` allows the executor to remain independent of the
proof mechanism. `SentinelECDSADecisionVerifier` is an immutable, low-s,
65-byte secp256k1 verifier suitable for a TEE-controlled signing key.

A future FCC-native verifier can validate ActionResult attestations directly by
implementing the same interface.

## Current execution model

The executor calls targets from its own address and balance. Therefore, a
registered policy's `account` must equal the executor address. Safe modules and
other smart-account adapters will be separate integrations.
EOF

  python3 - "$PROJECT_ROOT/README.md" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
entry = "- [Onchain policy and execution boundary](docs/onchain-enforcement.md)\n"
anchor = "- [Protocol v1 canonical encoding](docs/protocol-v1.md)\n"

if entry not in text:
    if anchor not in text:
        raise SystemExit("README Protocol v1 documentation anchor was not found")
    text = text.replace(anchor, anchor + entry, 1)

path.write_text(text, encoding="utf-8")
PY
}

archive_patch() {
  mkdir -p "$PROJECT_ROOT/scripts/patches"
  cp "$SCRIPT_PATH" "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH"
  chmod 0755 "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH"

  if [[ "$(dirname -- "$SCRIPT_PATH")" == "$PROJECT_ROOT" && "$SCRIPT_PATH" != "$PROJECT_ROOT/$ARCHIVE_RELATIVE_PATH" ]]; then
    rm -f "$SCRIPT_PATH"
  fi
}

format_and_verify() {
  cd "$PROJECT_ROOT"
  export PATH="/usr/local/go/bin:$HOME/.foundry/bin:$PATH"
  hash -r

  info "Formatting Solidity and Go sources"
  forge fmt
  gofmt -w go/pkg/protocol go/internal/protocolvectors go/cmd/protocol-vectors

  info "Checking patch integrity"
  bash -n "$ARCHIVE_RELATIVE_PATH"
  shellcheck scripts/sentinel/*.sh
  git diff --check

  info "Running the complete Sentinel verification suite"
  ./scripts/sentinel/verify.sh

  ok "All contract, protocol, Go, scaffold, and conformance checks passed."
}

verify_change_set() {
  cd "$PROJECT_ROOT"

  python3 <<'PY'
import subprocess

allowed = {
    "README.md",
    "contracts/SentinelECDSADecisionVerifier.sol",
    "contracts/SentinelExecutor.sol",
    "contracts/SentinelPolicyRegistry.sol",
    "contracts/interfaces/ISentinelDecisionVerifier.sol",
    "contracts/interfaces/ISentinelPolicyRegistry.sol",
    "contracts/libraries/SentinelProtocol.sol",
    "docs/onchain-enforcement.md",
    "scripts/patches/005-onchain-policy-executor.sh",
    "test/SentinelECDSADecisionVerifier.t.sol",
    "test/SentinelExecutor.t.sol",
    "test/SentinelPolicyRegistry.t.sol",
}

status = subprocess.check_output(
    ["git", "status", "--porcelain=v1", "--untracked-files=all"],
    text=True,
).splitlines()

unexpected = [line for line in status if line[3:] not in allowed]
if unexpected:
    raise SystemExit(
        "Unexpected files in Patch 005 change set:\n  "
        + "\n  ".join(unexpected)
    )
PY

  ok "Patch 005 changed only the intended files."
}

commit_atomic_history() {
  cd "$PROJECT_ROOT"

  git add \
    contracts/SentinelPolicyRegistry.sol \
    contracts/interfaces/ISentinelPolicyRegistry.sol \
    contracts/libraries/SentinelProtocol.sol
  git diff --cached --check
  git commit -m "feat(contracts): add versioned policy commitment registry"

  git add \
    contracts/SentinelExecutor.sol \
    contracts/SentinelECDSADecisionVerifier.sol \
    contracts/interfaces/ISentinelDecisionVerifier.sol
  git diff --cached --check
  git commit -m "feat(contracts): add replay-safe decision executor"

  git add \
    test/SentinelPolicyRegistry.t.sol \
    test/SentinelExecutor.t.sol \
    test/SentinelECDSADecisionVerifier.t.sol
  git diff --cached --check
  git commit -m "test(contracts): cover policy and execution security invariants"

  git add README.md docs/onchain-enforcement.md
  git diff --cached --check
  git commit -m "docs(contracts): document onchain enforcement boundary"

  git add "$ARCHIVE_RELATIVE_PATH"
  git diff --cached --check
  git commit -m "chore(project): archive onchain enforcement patch"

  [[ -z "$(git status --porcelain=v1)" ]] ||
    die "Working tree is not clean after Patch 005 commits."

  ok "Created five atomic Patch 005 commits."
}

push_feature_branch() {
  cd "$PROJECT_ROOT"
  git push -u origin "$FEATURE_BRANCH"

  printf '\n'
  ok "Patch 005 completed and pushed."
  printf 'Branch: %s\n' "$FEATURE_BRANCH"
  printf 'Head:   %s\n' "$(git rev-parse --short HEAD)"
  printf 'Base:   %s\n' "$BASE_BRANCH"
  printf '\nCommits:\n'
  git log --oneline "origin/$BASE_BRANCH..HEAD"
  printf '\nPull request:\n'
  printf 'https://github.com/prateushsharma/sentinel-fcc/compare/%s...%s?expand=1\n' \
    "$BASE_BRANCH" "$FEATURE_BRANCH"
  printf '\nNext stage: confidential policy schema and deterministic TEE policy engine.\n'
}

main() {
  require_command git
  require_command forge
  require_command go
  require_command gofmt
  require_command python3
  require_command shellcheck

  validate_and_create_branch

  cd "$PROJECT_ROOT"
  extend_protocol_version_accessors
  write_interfaces
  write_policy_registry
  write_decision_verifier
  write_executor
  write_contract_tests
  write_documentation
  archive_patch

  format_and_verify
  verify_change_set
  commit_atomic_history
  push_feature_branch
}

main "$@"
