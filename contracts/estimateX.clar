;; EstimateX - Enhanced Prediction Market Contract

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

;; Data maps
(define-map markets uint
  { 
    creator: principal, 
    question: (string-ascii 160), 
    deadline: uint, 
    resolved: bool, 
    outcome: (optional bool), 
    yes-pool: uint, 
    no-pool: uint 
  })

;; Track user positions in each market
(define-map user-positions { market-id: uint, user: principal } 
  { 
    yes-amount: uint, 
    no-amount: uint, 
    claimed: bool 
  })

;; Create market function
(define-public (create-market (id uint) (question (string-ascii 160)) (deadline uint))
  (begin
    ;; Check if market already exists
    (asserts! (is-none (map-get? markets id)) (err ERR-MARKET-EXISTS))
    ;; Check deadline is in the future
    (asserts! (> deadline stacks-block-height) (err ERR-MARKET-EXPIRED))
    
    (map-set markets id { 
      creator: tx-sender, 
      question: question, 
      deadline: deadline, 
      resolved: false, 
      outcome: none, 
      yes-pool: u0, 
      no-pool: u0 
    })
    (ok true)))

;; Enhanced buy function - FIXED VERSION
(define-public (buy (id uint) (yes bool) (amount uint))
  (let ((m (map-get? markets id))
        (user-pos (default-to { yes-amount: u0, no-amount: u0, claimed: false } 
                              (map-get? user-positions { market-id: id, user: tx-sender }))))
    (match m
      market
        (begin
          ;; Validate amount is positive
          (asserts! (> amount u0) (err ERR-INVALID-AMOUNT))
          ;; Check market hasn't expired
          (asserts! (<= stacks-block-height (get deadline market)) (err ERR-MARKET-EXPIRED))
          ;; Check market isn't resolved
          (asserts! (not (get resolved market)) (err ERR-MARKET-RESOLVED))
          
          ;; Attempt STX transfer with error handling
          (match (stx-transfer? amount tx-sender (as-contract tx-sender))
            success
              (begin
                ;; Update market pools using merge
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
          
          (map-set markets id (merge market { resolved: true, outcome: (some outcome) }))
          (ok true))
      (err ERR-MARKET-NOT-FOUND))))

;; Claim winnings
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
                
                (asserts! (> user-winning-amount u0) (err ERR-NO-POSITION))
                (asserts! (> winning-pool u0) (err ERR-NO-POSITION))
                
                ;; Calculate payout: (user's winning bet / total winning bets) * total pool
                (let ((payout (/ (* user-winning-amount total-pool) winning-pool)))
                  ;; Mark as claimed
                  (map-set user-positions { market-id: id, user: tx-sender }
                    (merge position { claimed: true }))
                  
                  ;; Transfer winnings
                  (match (as-contract (stx-transfer? payout tx-sender tx-sender))
                    success (ok payout)
                    error (err ERR-TRANSFER-FAILED)))))
          (err ERR-NO-POSITION))
      (err ERR-MARKET-NOT-FOUND))))

;; Read-only functions
(define-read-only (get-market (id uint))
  (map-get? markets id))

(define-read-only (get-user-position (market-id uint) (user principal))
  (map-get? user-positions { market-id: market-id, user: user }))