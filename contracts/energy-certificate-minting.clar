;; energy-certificate-minting
;; Smart contract for minting verified renewable energy certificates

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-CERTIFICATE-NOT-FOUND (err u201))
(define-constant ERR-INVALID-GENERATION-DATA (err u203))
(define-constant ERR-CERTIFICATE-RETIRED (err u208))

;; Certificate status constants
(define-constant CERT-STATUS-ACTIVE u1)
(define-constant CERT-STATUS-RETIRED u2)
(define-constant CERT-STATUS-TRADED u3)

;; Contract admin
(define-data-var contract-admin principal tx-sender)

;; Certificate counter
(define-data-var next-certificate-id uint u1)

;; Certificate registry
(define-map certificates uint {
  installation-id: uint,
  generation-kwh: uint,
  generation-period-start: uint,
  generation-period-end: uint,
  minting-date: uint,
  status: uint,
  owner: principal,
  certificate-type: (string-ascii 20),
  vintage-year: uint
})

;; Owner certificate tracking
(define-map owner-certificates principal (list 1000 uint))

;; Certificate metadata
(define-map certificate-metadata uint {
  name: (string-ascii 50),
  description: (string-ascii 200),
  properties: (string-ascii 500)
})

;; Mint renewable energy certificate
(define-public (mint-certificate 
  (installation-id uint) 
  (generation-kwh uint)
  (period-start uint)
  (period-end uint)
  (certificate-type (string-ascii 20)))
  (let (
    (certificate-id (var-get next-certificate-id))
    (vintage-year (/ period-start u52560)) ;; Approximate blocks per year
  )
    ;; Validate inputs
    (asserts! (> generation-kwh u0) ERR-INVALID-GENERATION-DATA)
    (asserts! (< period-start period-end) ERR-INVALID-GENERATION-DATA)
    
    ;; Create certificate
    (map-set certificates certificate-id {
      installation-id: installation-id,
      generation-kwh: generation-kwh,
      generation-period-start: period-start,
      generation-period-end: period-end,
      minting-date: stacks-block-height,
      status: CERT-STATUS-ACTIVE,
      owner: tx-sender,
      certificate-type: certificate-type,
      vintage-year: vintage-year
    })
    
    ;; Create certificate metadata
    (map-set certificate-metadata certificate-id {
      name: "Renewable Energy Certificate",
      description: "Verified renewable energy generation certificate",
      properties: "Green energy certificate with blockchain verification"
    })
    
    ;; Update owner certificate list
    (let ((owner-certs (default-to (list) (map-get? owner-certificates tx-sender))))
      (map-set owner-certificates tx-sender 
        (unwrap! (as-max-len? (append owner-certs certificate-id) u1000) ERR-INVALID-GENERATION-DATA)
      )
    )
    
    ;; Increment certificate counter
    (var-set next-certificate-id (+ certificate-id u1))
    
    (ok certificate-id)
  )
)

;; Retire certificate
(define-public (retire-certificate (certificate-id uint))
  (match (map-get? certificates certificate-id)
    certificate (begin
      ;; Only certificate owner can retire
      (asserts! (is-eq tx-sender (get owner certificate)) ERR-NOT-AUTHORIZED)
      
      ;; Verify certificate is active
      (asserts! (is-eq (get status certificate) CERT-STATUS-ACTIVE) ERR-CERTIFICATE-RETIRED)
      
      ;; Update certificate status
      (map-set certificates certificate-id (merge certificate {
        status: CERT-STATUS-RETIRED
      }))
      
      (ok true)
    )
    ERR-CERTIFICATE-NOT-FOUND
  )
)

;; Transfer certificate ownership
(define-public (transfer-certificate (certificate-id uint) (new-owner principal))
  (match (map-get? certificates certificate-id)
    certificate (begin
      ;; Only current owner can transfer
      (asserts! (is-eq tx-sender (get owner certificate)) ERR-NOT-AUTHORIZED)
      
      ;; Verify certificate is active
      (asserts! (is-eq (get status certificate) CERT-STATUS-ACTIVE) ERR-CERTIFICATE-RETIRED)
      
      ;; Update certificate owner
      (map-set certificates certificate-id (merge certificate {
        owner: new-owner,
        status: CERT-STATUS-TRADED
      }))
      
      ;; Update owner certificate lists
      (let (
        (current-certs (default-to (list) (map-get? owner-certificates tx-sender)))
        (new-owner-certs (default-to (list) (map-get? owner-certificates new-owner)))
      )
        (map-set owner-certificates new-owner 
          (unwrap! (as-max-len? (append new-owner-certs certificate-id) u1000) ERR-INVALID-GENERATION-DATA)
        )
      )
      
      (ok true)
    )
    ERR-CERTIFICATE-NOT-FOUND
  )
)

;; Get certificate details
(define-read-only (get-certificate (certificate-id uint))
  (map-get? certificates certificate-id)
)

;; Get certificate metadata
(define-read-only (get-certificate-metadata (certificate-id uint))
  (map-get? certificate-metadata certificate-id)
)

;; Get certificates by owner
(define-read-only (get-owner-certificates (owner principal))
  (map-get? owner-certificates owner)
)

;; Get total certificates count
(define-read-only (get-total-certificates)
  (- (var-get next-certificate-id) u1)
)

;; Check certificate status
(define-read-only (is-certificate-active (certificate-id uint))
  (match (map-get? certificates certificate-id)
    certificate (is-eq (get status certificate) CERT-STATUS-ACTIVE)
    false
  )
)

;; Get certificate vintage
(define-read-only (get-certificate-vintage (certificate-id uint))
  (match (map-get? certificates certificate-id)
    certificate (some (get vintage-year certificate))
    none
  )
)