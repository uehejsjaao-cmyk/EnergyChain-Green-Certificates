;; renewable-source-registry
;; Smart contract for registering and managing renewable energy installations

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INSTALLATION-NOT-FOUND (err u102))
(define-constant ERR-INVALID-CAPACITY (err u103))
(define-constant ERR-INVALID-SOURCE-TYPE (err u105))

;; Source type constants
(define-constant SOURCE-SOLAR u1)
(define-constant SOURCE-WIND u2)
(define-constant SOURCE-HYDRO u3)

;; Status constants
(define-constant STATUS-PENDING u1)
(define-constant STATUS-ACTIVE u2)

;; Contract owner
(define-data-var contract-owner principal tx-sender)

;; Installation counter
(define-data-var next-installation-id uint u1)

;; Installation registry
(define-map installations uint {
  owner: principal,
  source-type: uint,
  capacity-kw: uint,
  latitude: int,
  longitude: int,
  installation-date: uint,
  status: uint,
  total-generation-kwh: uint,
  equipment-serial: (string-ascii 100),
  maintenance-contact: (string-ascii 100)
})

;; Owner installations mapping
(define-map owner-installations principal (list 100 uint))

;; Register new renewable energy installation
(define-public (register-installation 
  (source-type uint) 
  (capacity-kw uint) 
  (latitude int) 
  (longitude int)
  (equipment-serial (string-ascii 100))
  (maintenance-contact (string-ascii 100)))
  (let (
    (installation-id (var-get next-installation-id))
  )
    ;; Validate input parameters
    (asserts! (and (>= source-type SOURCE-SOLAR) (<= source-type SOURCE-HYDRO)) ERR-INVALID-SOURCE-TYPE)
    (asserts! (> capacity-kw u0) ERR-INVALID-CAPACITY)
    
    ;; Create installation record
    (map-set installations installation-id {
      owner: tx-sender,
      source-type: source-type,
      capacity-kw: capacity-kw,
      latitude: latitude,
      longitude: longitude,
      installation-date: stacks-block-height,
      status: STATUS-PENDING,
      total-generation-kwh: u0,
      equipment-serial: equipment-serial,
      maintenance-contact: maintenance-contact
    })
    
    ;; Update owner installations list
    (let ((current-installations (default-to (list) (map-get? owner-installations tx-sender))))
      (map-set owner-installations tx-sender 
        (unwrap! (as-max-len? (append current-installations installation-id) u100) ERR-INVALID-CAPACITY))
    )
    
    ;; Increment counter
    (var-set next-installation-id (+ installation-id u1))
    
    (ok installation-id)
  )
)

;; Verify installation by contract owner
(define-public (verify-installation (installation-id uint))
  (let ((installation (unwrap! (map-get? installations installation-id) ERR-INSTALLATION-NOT-FOUND)))
    ;; Only contract owner can verify
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR-NOT-AUTHORIZED)
    
    ;; Update status to active
    (map-set installations installation-id (merge installation {
      status: STATUS-ACTIVE
    }))
    
    (ok true)
  )
)

;; Update generation data
(define-public (update-generation-data (installation-id uint) (generation-kwh uint))
  (let ((installation (unwrap! (map-get? installations installation-id) ERR-INSTALLATION-NOT-FOUND)))
    ;; Verify ownership or authorization
    (asserts! (or 
      (is-eq tx-sender (get owner installation)) 
      (is-eq tx-sender (var-get contract-owner))
    ) ERR-NOT-AUTHORIZED)
    
    ;; Update total generation
    (map-set installations installation-id (merge installation {
      total-generation-kwh: (+ (get total-generation-kwh installation) generation-kwh)
    }))
    
    (ok true)
  )
)

;; Get installation details
(define-read-only (get-installation (installation-id uint))
  (map-get? installations installation-id)
)

;; Get installations by owner
(define-read-only (get-owner-installations (owner principal))
  (map-get? owner-installations owner)
)

;; Get total installations count
(define-read-only (get-total-installations)
  (- (var-get next-installation-id) u1)
)

;; Check if installation is active
(define-read-only (is-installation-active (installation-id uint))
  (match (map-get? installations installation-id)
    installation (is-eq (get status installation) STATUS-ACTIVE)
    false
  )
)

;; Calculate installation efficiency
(define-read-only (calculate-efficiency (installation-id uint))
  (match (map-get? installations installation-id)
    installation 
      (let (
        (total-generation (get total-generation-kwh installation))
        (capacity (get capacity-kw installation))
        (theoretical-max (* capacity u8760)) ;; Annual hours
      )
        (if (> theoretical-max u0)
          (some (/ (* total-generation u100) theoretical-max))
          none
        )
      )
    none
  )
)