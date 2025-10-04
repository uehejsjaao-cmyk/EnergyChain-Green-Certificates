;; clean-energy-incentives  
;; Smart contract for distributing token rewards to encourage renewable energy adoption

;; Token definitions
(define-fungible-token green-token)

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u400))
(define-constant ERR-INSUFFICIENT-BALANCE (err u401))
(define-constant ERR-INVALID-AMOUNT (err u402))
(define-constant ERR-REWARD-NOT-FOUND (err u403))
(define-constant ERR-STAKING-NOT-FOUND (err u404))
(define-constant ERR-STAKING-LOCKED (err u405))

;; Reward type constants
(define-constant REWARD-TYPE-GENERATION u1)
(define-constant REWARD-TYPE-PURCHASE u2)
(define-constant REWARD-TYPE-STAKING u3)

;; Staking tier constants
(define-constant TIER-BRONZE u1)
(define-constant TIER-SILVER u2)
(define-constant TIER-GOLD u3)

;; Contract admin
(define-data-var contract-admin principal tx-sender)

;; Reward counter
(define-data-var next-reward-id uint u1)

;; Staking pool counter
(define-data-var next-pool-id uint u1)

;; Base reward rates (tokens per kWh)
(define-data-var generation-reward-rate uint u10)
(define-data-var purchase-reward-rate uint u5)

;; User reward tracking
(define-map user-rewards principal {
  total-earned: uint,
  total-claimed: uint,
  generation-rewards: uint,
  purchase-rewards: uint,
  staking-rewards: uint,
  last-claim-time: uint
})

;; Individual reward records
(define-map rewards uint {
  recipient: principal,
  reward-type: uint,
  amount: uint,
  creation-time: uint,
  claimed: bool
})

;; Staking pools
(define-map staking-pools uint {
  owner: principal,
  staked-amount: uint,
  stake-time: uint,
  lock-duration: uint,
  unlock-time: uint,
  tier: uint,
  rewards-earned: uint
})

;; Mint initial token supply
(define-public (mint-initial-supply (amount uint))
  (begin
    ;; Only admin can mint initial supply
    (asserts! (is-eq tx-sender (var-get contract-admin)) ERR-NOT-AUTHORIZED)
    
    ;; Mint tokens
    (try! (ft-mint? green-token amount tx-sender))
    
    (ok amount)
  )
)

;; Award generation rewards to energy producers
(define-public (award-generation-reward 
  (producer principal) 
  (generation-kwh uint)
  (installation-id uint))
  (let (
    (reward-id (var-get next-reward-id))
    (reward-amount (* generation-kwh (var-get generation-reward-rate)))
  )
    ;; Only admin can award
    (asserts! (is-eq tx-sender (var-get contract-admin)) ERR-NOT-AUTHORIZED)
    
    ;; Create reward record
    (map-set rewards reward-id {
      recipient: producer,
      reward-type: REWARD-TYPE-GENERATION,
      amount: reward-amount,
      creation-time: stacks-block-height,
      claimed: false
    })
    
    ;; Update user rewards
    (let ((user-reward (default-to {total-earned: u0, total-claimed: u0, generation-rewards: u0, purchase-rewards: u0, staking-rewards: u0, last-claim-time: u0} (map-get? user-rewards producer))))
      (map-set user-rewards producer (merge user-reward {
        total-earned: (+ (get total-earned user-reward) reward-amount),
        generation-rewards: (+ (get generation-rewards user-reward) reward-amount)
      }))
    )
    
    ;; Increment reward counter
    (var-set next-reward-id (+ reward-id u1))
    
    (ok reward-id)
  )
)

;; Award purchase rewards to certificate buyers
(define-public (award-purchase-reward 
  (buyer principal) 
  (certificate-kwh uint)
  (certificate-id uint))
  (let (
    (reward-id (var-get next-reward-id))
    (reward-amount (* certificate-kwh (var-get purchase-reward-rate)))
  )
    ;; Only admin can award
    (asserts! (is-eq tx-sender (var-get contract-admin)) ERR-NOT-AUTHORIZED)
    
    ;; Create reward record
    (map-set rewards reward-id {
      recipient: buyer,
      reward-type: REWARD-TYPE-PURCHASE,
      amount: reward-amount,
      creation-time: stacks-block-height,
      claimed: false
    })
    
    ;; Update user rewards
    (let ((user-reward (default-to {total-earned: u0, total-claimed: u0, generation-rewards: u0, purchase-rewards: u0, staking-rewards: u0, last-claim-time: u0} (map-get? user-rewards buyer))))
      (map-set user-rewards buyer (merge user-reward {
        total-earned: (+ (get total-earned user-reward) reward-amount),
        purchase-rewards: (+ (get purchase-rewards user-reward) reward-amount)
      }))
    )
    
    ;; Increment reward counter
    (var-set next-reward-id (+ reward-id u1))
    
    (ok reward-id)
  )
)

;; Stake tokens for rewards
(define-public (stake-tokens (amount uint) (lock-duration uint))
  (let (
    (pool-id (var-get next-pool-id))
    (unlock-time (+ stacks-block-height lock-duration))
    (stake-tier (calculate-stake-tier amount))
  )
    ;; Validate inputs
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (>= lock-duration u1440) ERR-INVALID-AMOUNT) ;; Minimum ~10 days
    
    ;; Transfer tokens to contract for staking
    (try! (ft-transfer? green-token amount tx-sender (as-contract tx-sender)))
    
    ;; Create staking pool
    (map-set staking-pools pool-id {
      owner: tx-sender,
      staked-amount: amount,
      stake-time: stacks-block-height,
      lock-duration: lock-duration,
      unlock-time: unlock-time,
      tier: stake-tier,
      rewards-earned: u0
    })
    
    ;; Increment pool counter
    (var-set next-pool-id (+ pool-id u1))
    
    (ok pool-id)
  )
)

;; Claim available rewards
(define-public (claim-rewards (reward-ids (list 50 uint)))
  (let ((total-claimed (fold claim-single-reward reward-ids u0)))
    ;; Transfer claimed tokens to user
    (if (> total-claimed u0)
      (try! (as-contract (ft-transfer? green-token total-claimed tx-sender tx-sender)))
      (ok u0)
    )
    
    ;; Update user claim time
    (let ((user-reward (default-to {total-earned: u0, total-claimed: u0, generation-rewards: u0, purchase-rewards: u0, staking-rewards: u0, last-claim-time: u0} (map-get? user-rewards tx-sender))))
      (map-set user-rewards tx-sender (merge user-reward {
        total-claimed: (+ (get total-claimed user-reward) total-claimed),
        last-claim-time: stacks-block-height
      }))
    )
    
    (ok total-claimed)
  )
)

;; Unstake tokens after lock period
(define-public (unstake-tokens (pool-id uint))
  (match (map-get? staking-pools pool-id)
    pool (begin
      ;; Verify ownership
      (asserts! (is-eq tx-sender (get owner pool)) ERR-NOT-AUTHORIZED)
      
      ;; Check if unlock time has passed
      (asserts! (>= stacks-block-height (get unlock-time pool)) ERR-STAKING-LOCKED)
      
      ;; Transfer staked tokens back to user
      (try! (as-contract (ft-transfer? green-token (get staked-amount pool) tx-sender tx-sender)))
      
      ;; Remove pool
      (map-delete staking-pools pool-id)
      
      (ok (get staked-amount pool))
    )
    ERR-STAKING-NOT-FOUND
  )
)

;; Get user rewards summary
(define-read-only (get-user-rewards (user principal))
  (map-get? user-rewards user)
)

;; Get reward details
(define-read-only (get-reward-details (reward-id uint))
  (map-get? rewards reward-id)
)

;; Get staking pool details
(define-read-only (get-staking-pool (pool-id uint))
  (map-get? staking-pools pool-id)
)

;; Get token balance
(define-read-only (get-balance (user principal))
  (ft-get-balance green-token user)
)

;; Get total token supply
(define-read-only (get-total-supply)
  (ft-get-supply green-token)
)

;; Check if user can claim reward
(define-read-only (can-claim-reward (reward-id uint) (user principal))
  (match (map-get? rewards reward-id)
    reward (and 
      (is-eq (get recipient reward) user)
      (not (get claimed reward))
    )
    false
  )
)

;; Get program statistics
(define-read-only (get-program-stats)
  {
    total-rewards-issued: (- (var-get next-reward-id) u1),
    total-staking-pools: (- (var-get next-pool-id) u1),
    generation-rate: (var-get generation-reward-rate),
    purchase-rate: (var-get purchase-reward-rate)
  }
)

;; Private functions

;; Calculate stake tier based on amount
(define-private (calculate-stake-tier (amount uint))
  (if (>= amount u25000)
    TIER-GOLD
    (if (>= amount u5000)
      TIER-SILVER
      TIER-BRONZE
    )
  )
)

;; Claim single reward helper
(define-private (claim-single-reward (reward-id uint) (acc uint))
  (match (map-get? rewards reward-id)
    reward 
      (if (and (is-eq (get recipient reward) tx-sender) (not (get claimed reward)))
        (begin
          ;; Mark reward as claimed
          (map-set rewards reward-id (merge reward {
            claimed: true
          }))
          (+ acc (get amount reward))
        )
        acc
      )
    acc
  )
)