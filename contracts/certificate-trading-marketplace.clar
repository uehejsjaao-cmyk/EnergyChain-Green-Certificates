;; certificate-trading-marketplace
;; Smart contract for peer-to-peer trading of renewable energy certificates

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u300))
(define-constant ERR-ORDER-NOT-FOUND (err u301))
(define-constant ERR-INVALID-PRICE (err u305))
(define-constant ERR-INVALID-QUANTITY (err u306))
(define-constant ERR-ORDER-INACTIVE (err u304))

;; Order status constants
(define-constant ORDER-STATUS-ACTIVE u1)
(define-constant ORDER-STATUS-FILLED u2)
(define-constant ORDER-STATUS-CANCELLED u3)

;; Order type constants
(define-constant ORDER-TYPE-BUY u1)
(define-constant ORDER-TYPE-SELL u2)

;; Contract admin
(define-data-var contract-admin principal tx-sender)

;; Order counter
(define-data-var next-order-id uint u1)

;; Trade counter
(define-data-var next-trade-id uint u1)

;; Order book
(define-map orders uint {
  creator: principal,
  certificate-id: uint,
  price-per-kwh: uint,
  quantity-kwh: uint,
  remaining-quantity: uint,
  order-type: uint,
  status: uint,
  creation-time: uint,
  expiration-time: uint
})

;; Trade history
(define-map trades uint {
  buy-order-id: uint,
  sell-order-id: uint,
  buyer: principal,
  seller: principal,
  certificate-id: uint,
  quantity-kwh: uint,
  price-per-kwh: uint,
  total-amount: uint,
  trade-time: uint
})

;; User trading statistics
(define-map user-stats principal {
  total-bought: uint,
  total-sold: uint,
  total-trades: uint
})

;; Create sell order for certificate
(define-public (create-sell-order 
  (certificate-id uint) 
  (price-per-kwh uint)
  (quantity-kwh uint)
  (expiration-blocks uint))
  (let (
    (order-id (var-get next-order-id))
    (expiration-time (+ stacks-block-height expiration-blocks))
  )
    ;; Validate inputs
    (asserts! (> price-per-kwh u0) ERR-INVALID-PRICE)
    (asserts! (> quantity-kwh u0) ERR-INVALID-QUANTITY)
    
    ;; Create sell order
    (map-set orders order-id {
      creator: tx-sender,
      certificate-id: certificate-id,
      price-per-kwh: price-per-kwh,
      quantity-kwh: quantity-kwh,
      remaining-quantity: quantity-kwh,
      order-type: ORDER-TYPE-SELL,
      status: ORDER-STATUS-ACTIVE,
      creation-time: stacks-block-height,
      expiration-time: expiration-time
    })
    
    ;; Increment order counter
    (var-set next-order-id (+ order-id u1))
    
    (ok order-id)
  )
)

;; Create buy order for certificates
(define-public (create-buy-order 
  (certificate-type (string-ascii 20))
  (price-per-kwh uint)
  (quantity-kwh uint)
  (expiration-blocks uint))
  (let (
    (order-id (var-get next-order-id))
    (expiration-time (+ stacks-block-height expiration-blocks))
  )
    ;; Validate inputs
    (asserts! (> price-per-kwh u0) ERR-INVALID-PRICE)
    (asserts! (> quantity-kwh u0) ERR-INVALID-QUANTITY)
    
    ;; Create buy order
    (map-set orders order-id {
      creator: tx-sender,
      certificate-id: u0, ;; generic order
      price-per-kwh: price-per-kwh,
      quantity-kwh: quantity-kwh,
      remaining-quantity: quantity-kwh,
      order-type: ORDER-TYPE-BUY,
      status: ORDER-STATUS-ACTIVE,
      creation-time: stacks-block-height,
      expiration-time: expiration-time
    })
    
    ;; Increment order counter
    (var-set next-order-id (+ order-id u1))
    
    (ok order-id)
  )
)

;; Cancel order
(define-public (cancel-order (order-id uint))
  (match (map-get? orders order-id)
    order (begin
      ;; Only order creator can cancel
      (asserts! (is-eq tx-sender (get creator order)) ERR-NOT-AUTHORIZED)
      
      ;; Only cancel active orders
      (asserts! (is-eq (get status order) ORDER-STATUS-ACTIVE) ERR-ORDER-INACTIVE)
      
      ;; Update order status
      (map-set orders order-id (merge order {
        status: ORDER-STATUS-CANCELLED
      }))
      
      (ok true)
    )
    ERR-ORDER-NOT-FOUND
  )
)

;; Execute trade between orders
(define-public (execute-trade (buy-order-id uint) (sell-order-id uint) (trade-quantity uint))
  (let (
    (buy-order (unwrap! (map-get? orders buy-order-id) ERR-ORDER-NOT-FOUND))
    (sell-order (unwrap! (map-get? orders sell-order-id) ERR-ORDER-NOT-FOUND))
    (trade-id (var-get next-trade-id))
    (trade-price (get price-per-kwh sell-order))
    (total-amount (* trade-price trade-quantity))
  )
    ;; Validate orders are active
    (asserts! (is-eq (get status buy-order) ORDER-STATUS-ACTIVE) ERR-ORDER-INACTIVE)
    (asserts! (is-eq (get status sell-order) ORDER-STATUS-ACTIVE) ERR-ORDER-INACTIVE)
    
    ;; Validate trade quantity
    (asserts! (> trade-quantity u0) ERR-INVALID-QUANTITY)
    (asserts! (<= trade-quantity (get remaining-quantity buy-order)) ERR-INVALID-QUANTITY)
    (asserts! (<= trade-quantity (get remaining-quantity sell-order)) ERR-INVALID-QUANTITY)
    
    ;; Create trade record
    (map-set trades trade-id {
      buy-order-id: buy-order-id,
      sell-order-id: sell-order-id,
      buyer: (get creator buy-order),
      seller: (get creator sell-order),
      certificate-id: (get certificate-id sell-order),
      quantity-kwh: trade-quantity,
      price-per-kwh: trade-price,
      total-amount: total-amount,
      trade-time: stacks-block-height
    })
    
    ;; Update order quantities
    (map-set orders buy-order-id (merge buy-order {
      remaining-quantity: (- (get remaining-quantity buy-order) trade-quantity),
      status: (if (is-eq (- (get remaining-quantity buy-order) trade-quantity) u0) 
                ORDER-STATUS-FILLED 
                ORDER-STATUS-ACTIVE)
    }))
    
    (map-set orders sell-order-id (merge sell-order {
      remaining-quantity: (- (get remaining-quantity sell-order) trade-quantity),
      status: (if (is-eq (- (get remaining-quantity sell-order) trade-quantity) u0) 
                ORDER-STATUS-FILLED 
                ORDER-STATUS-ACTIVE)
    }))
    
    ;; Update user statistics
    (let (
      (buyer-stats (default-to {total-bought: u0, total-sold: u0, total-trades: u0} (map-get? user-stats (get creator buy-order))))
      (seller-stats (default-to {total-bought: u0, total-sold: u0, total-trades: u0} (map-get? user-stats (get creator sell-order))))
    )
      (map-set user-stats (get creator buy-order) (merge buyer-stats {
        total-bought: (+ (get total-bought buyer-stats) total-amount),
        total-trades: (+ (get total-trades buyer-stats) u1)
      }))
      
      (map-set user-stats (get creator sell-order) (merge seller-stats {
        total-sold: (+ (get total-sold seller-stats) total-amount),
        total-trades: (+ (get total-trades seller-stats) u1)
      }))
    )
    
    ;; Increment trade counter
    (var-set next-trade-id (+ trade-id u1))
    
    (ok trade-id)
  )
)

;; Get order details
(define-read-only (get-order (order-id uint))
  (map-get? orders order-id)
)

;; Get trade details
(define-read-only (get-trade (trade-id uint))
  (map-get? trades trade-id)
)

;; Get user trading statistics
(define-read-only (get-user-stats (user principal))
  (map-get? user-stats user)
)

;; Get market statistics
(define-read-only (get-market-stats)
  {
    total-orders: (- (var-get next-order-id) u1),
    total-trades: (- (var-get next-trade-id) u1)
  }
)

;; Check if order is expired
(define-read-only (is-order-expired (order-id uint))
  (match (map-get? orders order-id)
    order (>= stacks-block-height (get expiration-time order))
    false
  )
)