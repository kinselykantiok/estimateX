;; EstimateX - Enhanced Prediction Market Contract with Security Features

;; Error constants
(define-constant ERR-MARKET-EXISTS u100)
(define-constant ERR-MARKET-NOT-FOUND u101)
(define-constant ERR-INVALID-AMOUNT u102)
(define-constant ERR-MARKET-EXPIRED u103)
(define-constant ERR-MARKET-RESOLVED u104)
(define-constant ERR-TRANSFER-FAILED u105)
(define-constant ERR-NOT-CREATOR u106)
(define-constant ERR-MARKET-NOT-EXPIRED u107)
(define-constant ERR-NO-POSITION u108)
(define-constant ERR-ALREADY-CLAIMED u109)
(define-constant ERR-MARKET-CANCELLED u110)
(define-constant ERR-INSUFFICIENT-LIQUIDITY u111)
(define-constant ERR-MANIPULATION-DETECTED u112)
(define-constant ERR-EMERGENCY-PAUSE u113)
(define-constant ERR-NOT-AUTHORIZED u114)

;; Contract state variables for security features
(define-data-var contract-paused bool false)
(define-data-var min-bet-amount uint u1000000) ;; 1 STX minimum
(define-data-var max-market-duration uint u144000) ;; ~100 days in blocks
(define-data-var contract-owner principal tx-sender)

;; Enhanced data maps
(define-map markets uint
  { 
    creator: principal, 
    question: (string-ascii 160), 
    deadline: uint, 
    resolved: bool, 
    outcome: (optional bool), 
    yes-pool: uint, 
    no-pool: uint,
    cancelled: bool,
    creation-block: uint,
    min-bet: uint
  })

;; Track user positions in each market
(define-map user-positions { market-id: uint, user: principal } 
  { 
    yes-amount: uint, 
    no-amount: uint, 
    claimed: bool 
  })

;; Security functions
(define-public (emergency-pause (pause bool))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) (err ERR-NOT-AUTHORIZED))
    (var-set contract-paused pause)
    (ok true)))

(define-public (update-min-bet (new-min uint))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) (err ERR-NOT-AUTHORIZED))
    (asserts! (>= new-min u100000) (err ERR-INVALID-AMOUNT)) ;; At least 0.1 STX
    (var-set min-bet-amount new-min)
    (ok true)))

;; Market manipulation detection
(define-private (detect-manipulation (market-id uint) (bet-amount uint) (yes bool))
  (let ((market (unwrap! (map-get? markets market-id) false))
        (current-yes-pool (get yes-pool market))
        (current-no-pool (get no-pool market))
        (total-pool (+ current-yes-pool current-no-pool)))
    
    ;; Flag as manipulation if single bet is >40% of existing pool (when pool > 10 STX)
    (if (> total-pool u10000000) ;; 10 STX threshold
      (< (* bet-amount u5) (* total-pool u2)) ;; bet-amount < total-pool * 2/5
      true))) ;; Allow any bet for small pools

;; Enhanced create market function
(define-public (create-market (id uint) (question (string-ascii 160)) (deadline uint))
  (create-market-enhanced id question deadline (var-get min-bet-amount)))

(define-public (create-market-enhanced (id uint) (question (string-ascii 160)) (deadline uint) (min-bet uint))
  (begin
    ;; Security checks
    (asserts! (not (var-get contract-paused)) (err ERR-EMERGENCY-PAUSE))
    (asserts! (is-none (map-get? markets id)) (err ERR-MARKET-EXISTS))
    (asserts! (and (> deadline stacks-block-height) 
                   (< (- deadline stacks-block-height) (var-get max-market-duration))) 
              (err ERR-MARKET-EXPIRED))
    (asserts! (>= min-bet (var-get min-bet-amount)) (err ERR-INVALID-AMOUNT))
    
    (map-set markets id { 
      creator: tx-sender, 
      question: question, 
      deadline: deadline, 
      resolved: false, 
      outcome: none, 
      yes-pool: u0, 
      no-pool: u0,
      cancelled: false,
      creation-block: stacks-block-height,
      min-bet: min-bet
    })
    (ok true)))

;; Enhanced buy function with security features
(define-public (buy (id uint) (yes bool) (amount uint))
  (let ((m (map-get? markets id))
        (user-pos (default-to { yes-amount: u0, no-amount: u0, claimed: false } 
                              (map-get? user-positions { market-id: id, user: tx-sender }))))
    (match m
      market
        (begin
          ;; Security checks
          (asserts! (not (var-get contract-paused)) (err ERR-EMERGENCY-PAUSE))
          (asserts! (not (get cancelled market)) (err ERR-MARKET-CANCELLED))
          (asserts! (>= amount (get min-bet market)) (err ERR-INVALID-AMOUNT))
          (asserts! (<= stacks-block-height (get deadline market)) (err ERR-MARKET-EXPIRED))
          (asserts! (not (get resolved market)) (err ERR-MARKET-RESOLVED))
          
          ;; Manipulation detection
          (asserts! (detect-manipulation id amount yes) (err ERR-MANIPULATION-DETECTED))
          
          ;; Proceed with transfer and updates
          (match (stx-transfer? amount tx-sender (as-contract tx-sender))
            success
              (begin
                ;; Update market pools
                (if yes
                  (map-set markets id (merge market { yes-pool: (+ (get yes-pool market) amount) }))
                  (map-set markets id (merge market { no-pool: (+ (get no-pool market) amount) })))
                
                ;; Update user position
                (map-set user-positions { market-id: id, user: tx-sender }
                  (if yes
                    (merge user-pos { yes-amount: (+ (get yes-amount user-pos) amount) })
                    (merge user-pos { no-amount: (+ (get no-amount user-pos) amount) })))
                
                (ok true))
            error (err ERR-TRANSFER-FAILED)))
      (err ERR-MARKET-NOT-FOUND))))

;; Resolve market (only creator can call after deadline)
(define-public (resolve-market (id uint) (outcome bool))
  (let ((m (map-get? markets id)))
    (match m
      market
        (begin
          ;; Only creator can resolve
          (asserts! (is-eq tx-sender (get creator market)) (err ERR-NOT-CREATOR))
          ;; Market must be expired
          (asserts! (> stacks-block-height (get deadline market)) (err ERR-MARKET-NOT-EXPIRED))
          ;; Market must not be already resolved
          (asserts! (not (get resolved market)) (err ERR-MARKET-RESOLVED))
          ;; Market must not be cancelled
          (asserts! (not (get cancelled market)) (err ERR-MARKET-CANCELLED))
          
          (map-set markets id (merge market { resolved: true, outcome: (some outcome) }))
          (ok true))
      (err ERR-MARKET-NOT-FOUND))))

;; Cancel market (only creator, only before any bets)
(define-public (cancel-market (id uint))
  (let ((m (map-get? markets id)))
    (match m
      market
        (begin
          (asserts! (is-eq tx-sender (get creator market)) (err ERR-NOT-CREATOR))
          (asserts! (not (get resolved market)) (err ERR-MARKET-RESOLVED))
          (asserts! (and (is-eq (get yes-pool market) u0) (is-eq (get no-pool market) u0)) (err ERR-INVALID-AMOUNT))
          
          (map-set markets id (merge market { cancelled: true }))
          (ok true))
      (err ERR-MARKET-NOT-FOUND))))

;; FIXED claim winnings with proper mathematical handling
(define-public (claim-winnings (id uint))
  (let ((m (map-get? markets id))
        (user-pos (map-get? user-positions { market-id: id, user: tx-sender })))
    (match m
      market
        (match user-pos
          position
            (begin
              ;; Market must be resolved
              (asserts! (get resolved market) (err ERR-MARKET-RESOLVED))
              ;; User must not have already claimed
              (asserts! (not (get claimed position)) (err ERR-ALREADY-CLAIMED))
              
              (let ((outcome (unwrap! (get outcome market) (err ERR-MARKET-RESOLVED)))
                    (total-pool (+ (get yes-pool market) (get no-pool market)))
                    (winning-pool (if outcome (get yes-pool market) (get no-pool market)))
                    (user-winning-amount (if outcome (get yes-amount position) (get no-amount position))))
                
                ;; Enhanced validation to prevent division by zero
                (asserts! (> user-winning-amount u0) (err ERR-NO-POSITION))
                (asserts! (> winning-pool u0) (err ERR-NO-POSITION))
                (asserts! (> total-pool u0) (err ERR-NO-POSITION))
                
                ;; Fixed payout calculation with precision handling
                ;; Use scaling factor to avoid precision loss in integer division
                (let ((scale-factor u1000000) ;; 6 decimal places of precision
                      (scaled-numerator (* (* user-winning-amount scale-factor) total-pool))
                      (payout (/ scaled-numerator winning-pool)))
                  
                  ;; Ensure payout is reasonable
                  (asserts! (> payout u0) (err ERR-NO-POSITION))
                  (asserts! (<= payout total-pool) (err ERR-INVALID-AMOUNT))
                  
                  ;; Mark as claimed first (reentrancy protection)
                  (map-set user-positions { market-id: id, user: tx-sender }
                    (merge position { claimed: true }))
                  
                  ;; Transfer winnings
                  (match (as-contract (stx-transfer? payout tx-sender tx-sender))
                    success (ok payout)
                    error 
                      (begin
                        ;; Revert claimed status on transfer failure
                        (map-set user-positions { market-id: id, user: tx-sender }
                          (merge position { claimed: false }))
                        (err ERR-TRANSFER-FAILED))))))
          (err ERR-NO-POSITION))
      (err ERR-MARKET-NOT-FOUND))))

;; Fund recovery for unresolved markets (after extended deadline)
(define-public (recover-funds (id uint))
  (let ((m (map-get? markets id))
        (user-pos (map-get? user-positions { market-id: id, user: tx-sender })))
    (match m
      market
        (match user-pos
          position
            (begin
              ;; Market must be expired for significant time without resolution (10 days grace period)
              (asserts! (> stacks-block-height (+ (get deadline market) u14400)) (err ERR-MARKET-NOT-EXPIRED))
              (asserts! (not (get resolved market)) (err ERR-MARKET-RESOLVED))
              (asserts! (not (get cancelled market)) (err ERR-MARKET-CANCELLED))
              (asserts! (not (get claimed position)) (err ERR-ALREADY-CLAIMED))
              
              (let ((user-total (+ (get yes-amount position) (get no-amount position))))
                (asserts! (> user-total u0) (err ERR-NO-POSITION))
                
                ;; Mark as claimed to prevent double recovery
                (map-set user-positions { market-id: id, user: tx-sender }
                  (merge position { claimed: true }))
                
                ;; Return original bet amount
                (match (as-contract (stx-transfer? user-total tx-sender tx-sender))
                  success (ok user-total)
                  error 
                    (begin
                      ;; Revert claimed status on transfer failure
                      (map-set user-positions { market-id: id, user: tx-sender }
                        (merge position { claimed: false }))
                      (err ERR-TRANSFER-FAILED)))))
          (err ERR-NO-POSITION))
      (err ERR-MARKET-NOT-FOUND))))

;; Read-only functions
(define-read-only (get-market (id uint))
  (map-get? markets id))

(define-read-only (get-user-position (market-id uint) (user principal))
  (map-get? user-positions { market-id: market-id, user: user }))

(define-read-only (get-contract-info)
  {
    paused: (var-get contract-paused),
    min-bet: (var-get min-bet-amount),
    max-duration: (var-get max-market-duration),
    owner: (var-get contract-owner)
  })

(define-read-only (calculate-potential-payout (market-id uint) (user principal))
  (let ((market (map-get? markets market-id))
        (position (map-get? user-positions { market-id: market-id, user: user })))
    (match market
      m (match position
          p (let ((total-pool (+ (get yes-pool m) (get no-pool m)))
                  (yes-pool (get yes-pool m))
                  (no-pool (get no-pool m))
                  (user-yes (get yes-amount p))
                  (user-no (get no-amount p)))
              (if (and (> yes-pool u0) (> user-yes u0))
                (some { 
                  yes-payout: (/ (* user-yes total-pool) yes-pool),
                  no-payout: (if (and (> no-pool u0) (> user-no u0)) 
                              (/ (* user-no total-pool) no-pool) 
                              u0)
                })
                (if (and (> no-pool u0) (> user-no u0))
                  (some { 
                    yes-payout: u0,
                    no-payout: (/ (* user-no total-pool) no-pool)
                  })
                  none)))
          none)
      none)))

(define-read-only (is-market-recoverable (market-id uint))
  (match (map-get? markets market-id)
    market
      (and 
        (not (get resolved market))
        (not (get cancelled market))
        (> stacks-block-height (+ (get deadline market) u14400)))
    false))
