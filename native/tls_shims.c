/*
 * Tangerine std::tls — native shim library (tls_shims.c)
 *
 * In-repository implementation of the custom extern family declared in
 * std/tls.tg (the `extern "C"` block at the bottom of the module). The
 * Tangerine module names these shims tls_x509_* / tls_ssl_* / tls_pkey_* /
 * tls_load_file; this file implements every one of them as a small,
 * deterministic wrapper over the system OpenSSL (libssl + libcrypto).
 *
 * Ownership contract (mirrors std/tls.tg):
 *   - tls_x509_from_pem / tls_pkey_from_pem return a FRESH native handle
 *     (refcount 1) owned by the Tangerine Certificate / PrivateKey wrapper;
 *     tls_x509_free / tls_pkey_free release exactly that ownership. The
 *     wrappers' Drop impls are the sole owners — a bit-level clone of the
 *     wrapper would double-free, which is why the TlsConfig builders are
 *     consuming (sink) operations instead of cloning.
 *   - tls_ssl_set_certificate / tls_ssl_set_private_key hand the X509 /
 *     EVP_PKEY to the SSL via SSL_use_certificate / SSL_use_PrivateKey,
 *     which take their OWN reference (OpenSSL increments the object's
 *     reference count on success), so the Tangerine wrapper may free its
 *     handle (Drop) after the handshake setup while the SSL keeps a valid
 *     copy.
 *   - tls_ssl_new returns a tg_ssl_handle { SSL_CTX, SSL } pair so no
 *     SSL_CTX lifetime questions exist; tls_ssl_free releases both.
 *   - Every DER/file write is bounded by the caller-supplied max_len; a
 *     result that does not fit returns -1 (the Tangerine side also bounds
 *     against its buffer capacity before set_len).
 *
 * Build (CI, .github/workflows/ci.yml stdlib-integration job):
 *   cc -fPIC -shared native/tls_shims.c -lssl -lcrypto -o build/libtg_tls_shims.dylib
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>
#include <openssl/pem.h>
#include <openssl/bio.h>
#include <openssl/evp.h>

/* ————————————————————————————————————————————————————————————
 * TLS/SSL (tls_ssl_*)
 * ———————————————————————————————————————————————————————————— */

typedef struct tg_ssl_handle {
  SSL_CTX *ctx;
  SSL     *ssl;
} tg_ssl_handle;

/* tls_ssl_new() -> SslPtr */
void *tls_ssl_new(void) {
  tg_ssl_handle *hs = (tg_ssl_handle *)calloc(1, sizeof(tg_ssl_handle));
  if (hs == NULL) return NULL;
  hs->ctx = SSL_CTX_new(TLS_method());
  if (hs->ctx == NULL) { free(hs); return NULL; }
  hs->ssl = SSL_new(hs->ctx);
  if (hs->ssl == NULL) { SSL_CTX_free(hs->ctx); free(hs); return NULL; }
  return hs;
}

/* tls_ssl_free(ssl: SslPtr) -> Unit */
void tls_ssl_free(void *ssl_handle) {
  if (ssl_handle == NULL) return;
  tg_ssl_handle *hs = (tg_ssl_handle *)ssl_handle;
  if (hs->ssl != NULL) SSL_free(hs->ssl);
  if (hs->ctx != NULL) SSL_CTX_free(hs->ctx);
  free(hs);
}

/* tls_ssl_set_min_version(ssl: SslPtr, version: u16) -> Unit */
void tls_ssl_set_min_version(void *ssl_handle, uint16_t version) {
  tg_ssl_handle *hs = (tg_ssl_handle *)ssl_handle;
  if (hs == NULL || hs->ssl == NULL) return;
  SSL_set_min_proto_version(hs->ssl, (int)version);
}

/* tls_ssl_set_max_version(ssl: SslPtr, version: u16) -> Unit */
void tls_ssl_set_max_version(void *ssl_handle, uint16_t version) {
  tg_ssl_handle *hs = (tg_ssl_handle *)ssl_handle;
  if (hs == NULL || hs->ssl == NULL) return;
  SSL_set_max_proto_version(hs->ssl, (int)version);
}

/* tls_ssl_set_hostname(ssl: SslPtr, hostname: Ptr[u8]) -> Unit */
void tls_ssl_set_hostname(void *ssl_handle, const unsigned char *hostname) {
  tg_ssl_handle *hs = (tg_ssl_handle *)ssl_handle;
  if (hs == NULL || hs->ssl == NULL || hostname == NULL) return;
  SSL_set_tlsext_host_name(hs->ssl, (const char *)hostname);
}

/* tls_ssl_set_certificate(ssl: SslPtr, cert: X509Ptr) -> Unit
 * SSL_use_certificate takes its own X509 reference on success: the
 * Tangerine Certificate wrapper keeps owning its handle. */
void tls_ssl_set_certificate(void *ssl_handle, void *cert) {
  tg_ssl_handle *hs = (tg_ssl_handle *)ssl_handle;
  if (hs == NULL || hs->ssl == NULL || cert == NULL) return;
  SSL_use_certificate(hs->ssl, (X509 *)cert);
}

/* tls_ssl_set_private_key(ssl: SslPtr, key: EvpPkeyPtr) -> Unit
 * SSL_use_PrivateKey takes its own EVP_PKEY reference on success. */
void tls_ssl_set_private_key(void *ssl_handle, void *key) {
  tg_ssl_handle *hs = (tg_ssl_handle *)ssl_handle;
  if (hs == NULL || hs->ssl == NULL || key == NULL) return;
  SSL_use_PrivateKey(hs->ssl, (EVP_PKEY *)key);
}

/* tls_ssl_set_verify(ssl: SslPtr, verify_peer: Bool, verify_hostname: Bool) -> Unit
 * Tangerine Bool is the 1-byte C _Bool. When hostname verification is
 * requested, the peer name is taken from the SNI name already set by
 * tls_ssl_set_hostname (the std::tls connect path sets the hostname before
 * calling this). */
void tls_ssl_set_verify(void *ssl_handle, _Bool verify_peer, _Bool verify_hostname) {
  tg_ssl_handle *hs = (tg_ssl_handle *)ssl_handle;
  if (hs == NULL || hs->ssl == NULL) return;
  SSL_set_verify(hs->ssl, verify_peer ? SSL_VERIFY_PEER : SSL_VERIFY_NONE, NULL);
  if (verify_hostname) {
    const char *name = SSL_get_servername(hs->ssl, TLSEXT_NAMETYPE_host_name);
    if (name != NULL) SSL_set1_host(hs->ssl, name);
  }
}

/* tls_ssl_connect(ssl: SslPtr, socket: i32) -> i32  (0 ok, -1 error) */
int tls_ssl_connect(void *ssl_handle, int socket) {
  tg_ssl_handle *hs = (tg_ssl_handle *)ssl_handle;
  if (hs == NULL || hs->ssl == NULL) return -1;
  BIO *bio = BIO_new_socket(socket, BIO_NOCLOSE);
  if (bio == NULL) return -1;
  SSL_set_bio(hs->ssl, bio, bio);  /* the SSL owns the BIO from here */
  if (SSL_connect(hs->ssl) != 1) return -1;
  return 0;
}

/* tls_ssl_accept(ssl: SslPtr, socket: i32) -> i32  (0 ok, -1 error) */
int tls_ssl_accept(void *ssl_handle, int socket) {
  tg_ssl_handle *hs = (tg_ssl_handle *)ssl_handle;
  if (hs == NULL || hs->ssl == NULL) return -1;
  BIO *bio = BIO_new_socket(socket, BIO_NOCLOSE);
  if (bio == NULL) return -1;
  SSL_set_bio(hs->ssl, bio, bio);
  if (SSL_accept(hs->ssl) != 1) return -1;
  return 0;
}

/* tls_ssl_read(ssl: SslPtr, buf: PtrMut[u8], len: usize) -> i32 */
int tls_ssl_read(void *ssl_handle, unsigned char *buf, size_t len) {
  tg_ssl_handle *hs = (tg_ssl_handle *)ssl_handle;
  if (hs == NULL || hs->ssl == NULL) return -1;
  if (len > INT_MAX) return -1;
  return SSL_read(hs->ssl, buf, (int)len);
}

/* tls_ssl_write(ssl: SslPtr, buf: Ptr[u8], len: usize) -> i32 */
int tls_ssl_write(void *ssl_handle, const unsigned char *buf, size_t len) {
  tg_ssl_handle *hs = (tg_ssl_handle *)ssl_handle;
  if (hs == NULL || hs->ssl == NULL) return -1;
  if (len > INT_MAX) return -1;
  return SSL_write(hs->ssl, buf, (int)len);
}

/* tls_ssl_shutdown(ssl: SslPtr) -> i32 */
int tls_ssl_shutdown(void *ssl_handle) {
  tg_ssl_handle *hs = (tg_ssl_handle *)ssl_handle;
  if (hs == NULL || hs->ssl == NULL) return -1;
  return SSL_shutdown(hs->ssl);
}

/* ————————————————————————————————————————————————————————————
 * X509 certificates (tls_x509_*)
 * ———————————————————————————————————————————————————————————— */

/* tls_x509_from_pem(pem: Ptr[u8], len: usize) -> X509Ptr
 * Returns a fresh X509 with refcount 1 (NULL on parse failure). */
void *tls_x509_from_pem(const unsigned char *pem, size_t len) {
  if (pem == NULL || len == 0 || len > INT_MAX) return NULL;
  BIO *bio = BIO_new_mem_buf(pem, (int)len);
  if (bio == NULL) return NULL;
  X509 *cert = PEM_read_bio_X509(bio, NULL, NULL, NULL);
  BIO_free(bio);
  return cert;
}

/* tls_x509_free(cert: X509Ptr) -> Unit */
void tls_x509_free(void *cert) {
  if (cert != NULL) X509_free((X509 *)cert);
}

/* tls_x509_to_der(cert: X509Ptr, buf: PtrMut[u8], max_len: usize) -> i32
 * DER length on success, -1 when the DER does not fit max_len or fails. */
int tls_x509_to_der(void *cert, unsigned char *buf, size_t max_len) {
  X509 *x = (X509 *)cert;
  if (x == NULL || buf == NULL) return -1;
  unsigned char *der = NULL;
  int n = i2d_X509(x, &der);  /* allocating form: der is OPENSSL_malloc'ed */
  if (n < 0) return -1;
  if ((size_t)n > max_len) { OPENSSL_free(der); return -1; }
  memcpy(buf, der, (size_t)n);
  OPENSSL_free(der);
  return n;
}

/* tls_x509_get_subject_cn(cert: X509Ptr, buf: PtrMut[u8], max_len: usize) -> Unit
 * NUL-terminated CN (possibly truncated to max_len - 1). */
void tls_x509_get_subject_cn(void *cert, unsigned char *buf, size_t max_len) {
  X509 *x = (X509 *)cert;
  if (x == NULL || buf == NULL || max_len == 0) return;
  X509_NAME *name = X509_get_subject_name(x);
  if (name == NULL) { buf[0] = 0; return; }
  int n = X509_NAME_get_text_by_NID(name, NID_commonName, (char *)buf, (int)max_len);
  if (n < 0) {
    buf[0] = 0;
  } else if ((size_t)n >= max_len) {
    buf[max_len - 1] = 0;  /* truncated, still NUL-terminated */
  } else {
    buf[n] = 0;
  }
}

/* tls_x509_is_expired(cert: X509Ptr) -> i32  (1 expired, 0 not) */
int tls_x509_is_expired(void *cert) {
  X509 *x = (X509 *)cert;
  if (x == NULL) return 1;
  const ASN1_TIME *not_after = X509_get0_notAfter(x);
  if (not_after == NULL) return 1;  /* no expiry bound — treat as expired */
  return X509_cmp_current_time(not_after) < 0 ? 1 : 0;
}

/* ————————————————————————————————————————————————————————————
 * Private keys (tls_pkey_*)
 * ———————————————————————————————————————————————————————————— */

/* tls_pkey_from_pem(pem: Ptr[u8], len: usize, password: Ptr[u8]) -> EvpPkeyPtr
 * Returns a fresh EVP_PKEY with refcount 1 (NULL on parse failure);
 * password may be NULL for unencrypted keys. */
void *tls_pkey_from_pem(const unsigned char *pem, size_t len, const unsigned char *password) {
  if (pem == NULL || len == 0 || len > INT_MAX) return NULL;
  BIO *bio = BIO_new_mem_buf(pem, (int)len);
  if (bio == NULL) return NULL;
  EVP_PKEY *key = PEM_read_bio_PrivateKey(bio, NULL, NULL, (char *)password);
  BIO_free(bio);
  return key;
}

/* tls_pkey_free(key: EvpPkeyPtr) -> Unit */
void tls_pkey_free(void *key) {
  if (key != NULL) EVP_PKEY_free((EVP_PKEY *)key);
}

/* tls_pkey_to_der(key: EvpPkeyPtr, buf: PtrMut[u8], max_len: usize) -> i32
 * DER length on success, -1 when the DER does not fit max_len or fails. */
int tls_pkey_to_der(void *key, unsigned char *buf, size_t max_len) {
  EVP_PKEY *k = (EVP_PKEY *)key;
  if (k == NULL || buf == NULL) return -1;
  unsigned char *der = NULL;
  int n = i2d_PrivateKey(k, &der);  /* allocating form */
  if (n < 0) return -1;
  if ((size_t)n > max_len) { OPENSSL_free(der); return -1; }
  memcpy(buf, der, (size_t)n);
  OPENSSL_free(der);
  return n;
}

/* ————————————————————————————————————————————————————————————
 * File loading (tls_load_file)
 * ———————————————————————————————————————————————————————————— */

/* tls_load_file(path: Ptr[u8], buf: PtrMut[u8], max_len: usize) -> i32
 * Bytes read (capped at max_len) on success, -1 on open failure. The
 * caller bounds the result against its buffer capacity. */
int tls_load_file(const unsigned char *path, unsigned char *buf, size_t max_len) {
  if (path == NULL || buf == NULL) return -1;
  FILE *f = fopen((const char *)path, "rb");
  if (f == NULL) return -1;
  size_t n = fread(buf, 1, max_len, f);
  fclose(f);
  return (int)n;
}
