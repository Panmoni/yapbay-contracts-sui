# YapBay Dispute Resolution System Requirements

## Overview

This document outlines the requirements for YapBay's dispute resolution system, detailing the process, technical implementation, and data management requirements. This system aims to provide a fair, efficient, and transparent mechanism for resolving disputes between buyers and sellers.

## 1. Dispute Initiation

### Fee Structure
- **Bond Requirement**: Both parties must post a bond equal to 5% of the transaction value to participate in the dispute process
- **Fee Handling**: 
  - Winning party receives their bond back in full
  - Losing party's bond is allocated to cover arbitration costs and platform maintenance
  - Fee transfer happens automatically upon dispute resolution

### Smart Contract Implementation
- **Function Enhancements**: 
  - Modify `open_dispute` to accept a deposit of USDC equivalent to 5% of transaction value
  - Implement deposit tracking within the escrow struct
  - Add state to track which party has initiated the dispute
  - Implement countdown timer for opposing party response (72 hours)

### Evidence Submission Requirements
- **Initial Evidence**: 
  - Dispute initiator must submit:
    - One PDF document containing detailed evidence
    - One text statement (≤1000 characters) summarizing their position
  - PDF size limit: 5MB

### Technical Implementation
- **Evidence Storage**:
  - Store PDF files in AWS S3 bucket with appropriate security controls
  - Generate unique identifier for each evidence submission
  - Calculate SHA-256 hash of PDF and text submission
  - Record hash on-chain as part of dispute initiation transaction
  - Store evidence metadata and content references in PostgreSQL `dispute_evidence` table

### Database Schema Additions
```sql
CREATE TABLE dispute_evidence (
    id SERIAL PRIMARY KEY,
    escrow_id BIGINT REFERENCES escrows(id),
    trade_id BIGINT REFERENCES trades(id),
    submitter_address TEXT NOT NULL,
    submission_time TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    evidence_text TEXT NOT NULL,
    pdf_s3_path TEXT NOT NULL,
    evidence_hash TEXT NOT NULL,
    is_initial_submission BOOLEAN DEFAULT FALSE
);
```

### Response Mechanism
- **Notification System**: 
  - Automatic notification to opposing party when dispute is initiated
  - Countdown timer display showing remaining time to respond
  - Daily reminder notifications as deadline approaches

- **Opposition Response**:
  - Opposing party must post their own 5% bond within 72 hours
  - Must submit their evidence in the same format (1 PDF + 1000 char text)
  - Same hashing and storage process applies to their submission

- **Default Judgment**:
  - If opposing party fails to respond within 72 hours:
    - Mark dispute as eligible for default judgment
    - Notify arbitrator of non-response
    - Apply account sanctions to non-responsive party in PostgreSQL user record

## 2. Evidence Collection Phase

### Time Restrictions
- **Submission Window**: 72 hours from dispute initiation for both parties to submit all evidence
- **Late Evidence**: System rejects any evidence submitted after the deadline

### Evidence Privacy
- **Sealed Evidence Model**:
  - Evidence is not viewable by opposing party until submission period ends
  - After submission period ends, both parties can view all evidence
  - Implement access controls in database and file storage to enforce privacy

### Structured Evidence Format
- **File Requirements**:
  - PDF must follow provided template (template pending)
  - Evidence must be categorized according to predefined types:
    - Transaction receipts
    - Communication logs
    - Bank statements
    - Other supporting documents

### Technical Implementation
- **Storage and Retrieval**:
  - Implement PDF viewer in the dispute dashboard
  - Create API endpoints for secure retrieval of evidence
  - Implement verification that retrieved evidence matches on-chain hash

## 3. Arbitration Process

### Arbitrator Configuration
- **Initial Implementation**:
  - Use constant arbitrator address defined in smart contract
  - Address: `0x4ac605c28e73b516db9d0bf4caf538790558a73d7ce6b837fb69449eebfb431d`

### Arbitrator Interface
- **Dashboard Requirements**:
  - List of open disputes requiring resolution
  - Evidence viewer for all submitted materials
  - Resolution input form with structured decision options
  - Countdown timer showing remaining time for resolution

### Resolution Timeframe
- **Time Limit**: 168 hours (7 days) from the completion of evidence submission
- **Tracking**: System tracks time to resolution and flags overdue cases

### Decision Guidelines
- **Document Requirements**:
  - Develop and publish clear arbitration guidelines on the website
  - Guidelines should cover common dispute scenarios:
    - Non-payment issues
    - Fraudulent claims
    - Delay-related disputes
    - Identity verification issues
  - Guidelines will be referenced in unique identifiers to support the written decision

## 4. Resolution and Enforcement

### Decision Recording
- **Written Decision**:
  - Arbitrator must provide explanation (≤2000 characters)
  - Decision must reference relevant guidelines and evidence
  - Decision is stored in PostgreSQL database
  - Hash of decision is recorded on-chain

### Database Schema Addition
```sql
CREATE TABLE dispute_resolutions (
    id SERIAL PRIMARY KEY,
    dispute_id BIGINT REFERENCES disputes(id),
    arbitrator_address TEXT NOT NULL,
    resolution_time TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    decision TEXT NOT NULL,
    decision_explanation TEXT NOT NULL,
    decision_hash TEXT NOT NULL,
    winner_address TEXT NOT NULL,
    funds_destination TEXT NOT NULL
);
```

### Enforcement Implementation
- **Smart Contract Execution**:
  - Enhance `resolve_dispute` function to:
    - Transfer escrow funds to winning party
    - Return bond to winning party
    - Allocate losing party's bond to predefined platform address
  - Record resolution details in on-chain event

### Resolution Notification
- **User Communication**:
  - Send notification to both parties when dispute is resolved
  - Provide detailed resolution summary and next steps
  - Include appeal information if applicable (future roadmap)

## 5. Future Roadmap Items (Not In Current Implementation)

### Appeal System
- Future enhancement to allow appeals for disputes over certain value threshold
- Will require higher bond amount
- Multi-arbitrator panel for appeals

### Reputation System
- Track dispute history for all users
- Implement reputation scoring algorithm
- Display dispute-related reputation metrics on user profiles

### Precedent Database
- Build searchable database of anonymized resolutions
- Categorize by dispute type and outcome
- Provide as reference for users and future arbitrations

### Community Arbitration
- Transition from centralized to community-based arbitration
- Implement arbitrator selection and qualification system
- Create incentive structure for community arbitrators

## Technical Integration Requirements

### Smart Contract Modifications
- Add new state variables to `Escrow` struct:
  - `dispute_initiator: address`
  - `dispute_bond_buyer: Option<Coin<USDC>>`
  - `dispute_bond_seller: Option<Coin<USDC>>`
  - `dispute_initiated_time: u64`
  - `dispute_evidence_hash_buyer: Option<vector<u8>>`
  - `dispute_evidence_hash_seller: Option<vector<u8>>`
  - `dispute_resolution_hash: Option<vector<u8>>`

- New functions to implement:
  - `open_dispute_with_bond`
  - `respond_to_dispute_with_bond`
  - `resolve_dispute_with_explanation`

### Database Modifications
- New tables as defined above
- Additional columns in existing tables to track dispute status

### API Layer Requirements
- New endpoints for:
  - Dispute initiation with evidence submission
  - Evidence retrieval
  - Dispute status checking
  - Arbitrator decision submission

### User Interface Requirements
- Dispute initiation workflow
- Evidence submission forms
- Dispute status dashboard
- Arbitrator interface
- Resolution notification and explanation view

## Implementation Phases

### Phase 1 (Current Implementation)
- Implement basic dispute capability with bond requirement
- Setup evidence storage and hashing system
- Create PostgreSQL schema extensions
- Implement arbitrator decision recording

### Phase 2 (Next Iteration)
- Build out user interfaces for dispute process
- Implement notification system
- Create arbitrator dashboard
- Enhance reporting and analytics

### Phase 3 (Future Roadmap)
- Implement reputation system
- Develop appeal process
- Build precedent database
- Begin transition to community arbitration

## Testing Requirements

- Unit tests for all smart contract functions
- Integration tests for entire dispute flow
- Load testing with multiple simultaneous disputes
- Security audits for evidence storage and access controls
- User acceptance testing with simulated disputes