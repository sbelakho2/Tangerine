/*
 * Tangerine std::tls — native shim library (tls_shims.c)
 *
 * In-repository implementation of the custom extern family declared in
 * std/tls.tg (the `extern "C"` block at the bottom of the module). The
 * Tangerine module names these shims tls_x509_* / tls_ssl_* / tls_pkey_* /
 * tls_load_file; this file implements every one of them as a small,
 * deterministic wrapper over the system OpenSSL (libssl + libcrypto).
 *
 * The ssl-side family covers the full connection setup: the TLS version
 * selection (SSL_set_min/max_proto_version), the trust roots
 * (SSL_CTX_set_default_verify_paths + per-cert X509_STORE_add_cert — the
 * in-memory equivalent of SSL_CTX_load_verify_locations for the config's
 * ca_certs), the client ALPN offer (SSL_set_alpn_protos), the server
 * ALPN selection (SSL_select_next_proto in the select callback — the
 * selection is copied into the handle's stable buffer because the
 * negotiated pointer from SSL_select_next_proto points into the client's
 * message memory), the negotiated-protocol readout
 * (SSL_get0_alpn_selected), and the cipher restrictions
 * (SSL_set_cipher_list for TLS <= 1.2 and SSL_set_ciphersuites for
 * TLS 1.3). The version/cipher/ALPN-offer calls are the SSL-LEVEL forms
 * on purpose: the handle creates the SSL inside tls_ssl_new, and the
 * CTX-level equivalents are copied into the SSL at SSL_new, so a
 * CTX-level change after creation would not reach the handshake. The
 * trust-store calls stay CTX-level (the SSL's verification reads the
 * CTX's store live). Session resumption is NOT implemented (the module
 * header no longer claims it).
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
  unsigned char *alpn_protos;  /* server-side ALPN list (owned copy, wire format) */
  size_t  alpn_len;
  unsigned char alpn_selected[64];  /* stable copy of the negotiated protocol (length-prefixed) */
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
  if (hs->alpn_protos != NULL) free(hs->alpn_protos);
  free(hs);
}

/* tls_ssl_set_min_version(ssl: SslPtr, version: u16) -> Unit
 * The version floor. The SSL-LEVEL call (NOT SSL_CTX_set_min_proto_
 * version): the handle creates the SSL inside tls_ssl_new, and the CTX
 * limits are copied into the SSL at SSL_new — setting them on the CTX
 * afterwards would be too late for the handshake. */
void tls_ssl_set_min_version(void *ssl_handle, uint16_t version) {
  tg_ssl_handle *hs = (tg_ssl_handle *)ssl_handle;
  if (hs == NULL || hs->ssl == NULL) return;
  SSL_set_min_proto_version(hs->ssl, (int)version);
}

/* tls_ssl_set_max_version(ssl: SslPtr, version: u16) -> Unit
 * The version ceiling — same SSL-level rationale as set_min_version. */
void tls_ssl_set_max_version(void *ssl_handle, uint16_t version) {
  tg_ssl_handle *hs = (tg_ssl_handle *)ssl_handle;
  if (hs == NULL || hs->ssl == NULL) return;
  SSL_set_max_proto_version(hs->ssl, (int)version);
}

/* tls_ssl_set_default_verify_paths(ssl: SslPtr) -> Unit
 * The trust-root loading: SSL_CTX_set_default_verify_paths installs the
 * platform default CA store (/etc/ssl/cert.pem & co.), so verify_peer
 * works against the public trust roots the shim previously ignored. */
void tls_ssl_set_default_verify_paths(void *ssl_handle) {
  tg_ssl_handle *hs = (tg_ssl_handle *)ssl_handle;
  if (hs == NULL || hs->ctx == NULL) return;
  SSL_CTX_set_default_verify_paths(hs->ctx);
}

/* tls_ssl_add_ca_cert(ssl: SslPtr, cert: X509Ptr) -> Unit
 * The config's CA certificates: adds the parsed X509 to the CTX trust
 * store — the in-memory equivalent of SSL_CTX_load_verify_locations
 * (which requires a FILE PATH; the Tangerine side already holds the
 * parsed handles). X509_STORE_add_cert takes its own duplicate, so the
 * Tangerine Certificate wrapper's later free is safe. */
void tls_ssl_add_ca_cert(void *ssl_handle, void *cert) {
  tg_ssl_handle *hs = (tg_ssl_handle *)ssl_handle;
  if (hs == NULL || hs->ctx == NULL || cert == NULL) return;
  X509_STORE_add_cert(SSL_CTX_get_cert_store(hs->ctx), (X509 *)cert);
}

/* tls_ssl_set_alpn_protos(ssl: SslPtr, protos: Ptr[u8], len: usize) -> i32
 * Client-side ALPN offer in wire format (length-prefixed protocols).
 * The SSL-level call (NOT SSL_CTX_set_alpn_protos): the handle creates
 * the SSL inside tls_ssl_new, and the CTX-level list is copied into the
 * SSL at SSL_new — setting it on the CTX afterwards would be too late
 * for the ClientHello. SSL_set_alpn_protos copies the list.
 * 0 on success, -1 on error. */
int tls_ssl_set_alpn_protos(void *ssl_handle, const unsigned char *protos, size_t len) {
  tg_ssl_handle *hs = (tg_ssl_handle *)ssl_handle;
  if (hs == NULL || hs->ssl == NULL) return -1;
  if (len > INT_MAX) return -1;
  return SSL_set_alpn_protos(hs->ssl, protos, (unsigned int)len);
}

/* Server-side ALPN selection: SSL_select_next_proto picks the first
 * server protocol the client also offered. SSL_select_next_proto's *out
 * points INTO THE CLIENT'S MESSAGE buffer, which OpenSSL frees before
 * the ServerHello is written — the selection is copied into the
 * handle's stable buffer, and *out is redirected to that copy. */
static int tg_alpn_select_cb(SSL *ssl, const unsigned char **out, unsigned char *outlen,
                             const unsigned char *in, unsigned int inlen, void *arg) {
  tg_ssl_handle *hs = (tg_ssl_handle *)arg;
  (void)ssl;
  if (hs == NULL || hs->alpn_protos == NULL || hs->alpn_len == 0) {
    return SSL_TLSEXT_ERR_NOACK;
  }
  if (SSL_select_next_proto((unsigned char **)out, outlen, hs->alpn_protos,
                            (unsigned int)hs->alpn_len, in, inlen) == OPENSSL_NPN_NEGOTIATED) {
    if (*outlen > sizeof(hs->alpn_selected) - 1) {
      return SSL_TLSEXT_ERR_NOACK;
    }
    hs->alpn_selected[0] = *outlen;
    memcpy(hs->alpn_selected + 1, *out, *outlen);
    *out = hs->alpn_selected + 1;
    return SSL_TLSEXT_ERR_OK;
  }
  return SSL_TLSEXT_ERR_NOACK;
}

/* tls_ssl_set_alpn_select(ssl: SslPtr, protos: Ptr[u8], len: usize) -> i32
 * Server-side ALPN: registers the select callback over an OWNED COPY of
 * the server's protocol list (the caller's buffer must not outlive the
 * call). 0 on success, -1 on error. */
int tls_ssl_set_alpn_select(void *ssl_handle, const unsigned char *protos, size_t len) {
  tg_ssl_handle *hs = (tg_ssl_handle *)ssl_handle;
  if (hs == NULL || hs->ctx == NULL) return -1;
  unsigned char *copy = NULL;
  if (len > 0) {
    copy = (unsigned char *)malloc(len);
    if (copy == NULL) return -1;
    memcpy(copy, protos, len);
  }
  if (hs->alpn_protos != NULL) free(hs->alpn_protos);
  hs->alpn_protos = copy;
  hs->alpn_len = len;
  SSL_CTX_set_alpn_select_cb(hs->ctx, tg_alpn_select_cb, hs);
  return 0;
}

/* tls_ssl_get_alpn(ssl: SslPtr, buf: PtrMut[u8], max_len: usize) -> i32
 * The NEGOTIATED ALPN protocol (raw bytes, no length prefix) into the
 * caller's buffer; returns the byte count, 0 when no protocol was
 * negotiated, -1 when the result does not fit. */
int tls_ssl_get_alpn(void *ssl_handle, unsigned char *buf, size_t max_len) {
  tg_ssl_handle *hs = (tg_ssl_handle *)ssl_handle;
  if (hs == NULL || hs->ssl == NULL || buf == NULL) return 0;
  const unsigned char *proto = NULL;
  unsigned int len = 0;
  SSL_get0_alpn_selected(hs->ssl, &proto, &len);
  if (proto == NULL || len == 0) return 0;
  if ((size_t)len > max_len) return -1;
  memcpy(buf, proto, (size_t)len);
  return (int)len;
}

/* tls_ssl_set_cipher_list(ssl: SslPtr, ciphers: Ptr[u8]) -> i32
 * TLS 1.2 (and below) cipher restriction with the OpenSSL cipher names
 * (colon-separated). The SSL-LEVEL call (NOT SSL_CTX_set_cipher_list):
 * the SSL inherits the CTX's cipher list at SSL_new, so a CTX-level
 * change after the handle was created is not applied to the handshake.
 * 1 on success (the OpenSSL convention), 0 on failure. */
int tls_ssl_set_cipher_list(void *ssl_handle, const unsigned char *ciphers) {
  tg_ssl_handle *hs = (tg_ssl_handle *)ssl_handle;
  if (hs == NULL || hs->ssl == NULL || ciphers == NULL) return 0;
  return SSL_set_cipher_list(hs->ssl, (const char *)ciphers);
}

/* tls_ssl_set_cipher_suites(ssl: SslPtr, ciphers: Ptr[u8]) -> i32
 * TLS 1.3 cipher restriction with the IANA suite names (colon-separated)
 * — SSL-level for the same reason as set_cipher_list. 1 on success, 0 on
 * failure. */
int tls_ssl_set_cipher_suites(void *ssl_handle, const unsigned char *ciphers) {
  tg_ssl_handle *hs = (tg_ssl_handle *)ssl_handle;
  if (hs == NULL || hs->ssl == NULL || ciphers == NULL) return 0;
  return SSL_set_ciphersuites(hs->ssl, (const char *)ciphers);
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
