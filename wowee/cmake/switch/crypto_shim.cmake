# WoWee switch build: OpenSSL-compatible crypto shim.
#
# include(cmake/switch/crypto_shim.cmake) from the top-level CMakeLists.txt when
# WOWEE_SWITCH is on, *instead of* find_package(OpenSSL).  It defines:
#
#   WOWEE_SWITCH_crypto      STATIC library implementing the OpenSSL subset WoWee
#                         uses (BN, SHA1/SHA256/MD5, HMAC, EVP digests,
#                         RAND_bytes, and the EVP_PKEY_fromdata /
#                         EVP_PKEY_verify_recover RSA path of warden_module.cpp).
#                         PUBLIC include dir: switch/compat, so the unchanged
#                         #include <openssl/*.h> lines resolve to the shim.
#   OpenSSL::Crypto       ALIAS of WOWEE_SWITCH_crypto (only if not already defined)
#   OpenSSL::SSL          INTERFACE target linking WOWEE_SWITCH_crypto (only if not
#                         already defined) so existing target_link_libraries()
#                         lines keep working; no TLS is provided.
#   WOWEE_SWITCH_CRYPTO_SHIM_DIR   the switch/compat directory
#   OPENSSL_VERSION       "shim" (for the configuration summary)
#
# Tests: switch/compat/tests/run_crypto_tests.sh (host reference comparison against
# the system libcrypto + switch cross-compile/link probe).

get_filename_component(WOWEE_SWITCH_CRYPTO_SHIM_DIR "${CMAKE_CURRENT_LIST_DIR}/../../switch/compat" ABSOLUTE)
set(WOWEE_SWITCH_CRYPTO_SHIM_DIR "${WOWEE_SWITCH_CRYPTO_SHIM_DIR}" CACHE INTERNAL "WoWee switch crypto shim root")

set(WOWEE_SWITCH_CRYPTO_SOURCES
    ${WOWEE_SWITCH_CRYPTO_SHIM_DIR}/src/bn.cpp
    ${WOWEE_SWITCH_CRYPTO_SHIM_DIR}/src/sha1.cpp
    ${WOWEE_SWITCH_CRYPTO_SHIM_DIR}/src/sha256.cpp
    ${WOWEE_SWITCH_CRYPTO_SHIM_DIR}/src/md5.cpp
    ${WOWEE_SWITCH_CRYPTO_SHIM_DIR}/src/evp.cpp
    ${WOWEE_SWITCH_CRYPTO_SHIM_DIR}/src/hmac.cpp
    ${WOWEE_SWITCH_CRYPTO_SHIM_DIR}/src/rand.cpp
    ${WOWEE_SWITCH_CRYPTO_SHIM_DIR}/src/rsa.cpp
)

add_library(WOWEE_SWITCH_crypto STATIC ${WOWEE_SWITCH_CRYPTO_SOURCES})
target_include_directories(WOWEE_SWITCH_crypto
    PUBLIC  ${WOWEE_SWITCH_CRYPTO_SHIM_DIR}
    PRIVATE ${WOWEE_SWITCH_CRYPTO_SHIM_DIR}/src)
target_compile_features(WOWEE_SWITCH_crypto PUBLIC cxx_std_17)
target_compile_definitions(WOWEE_SWITCH_crypto PUBLIC WOWEE_CRYPTO_SHIM=1)

if(NOT TARGET OpenSSL::Crypto)
    add_library(OpenSSL::Crypto ALIAS WOWEE_SWITCH_crypto)
endif()
if(NOT TARGET OpenSSL::SSL)
    add_library(WOWEE_SWITCH_ssl_stub INTERFACE)
    target_link_libraries(WOWEE_SWITCH_ssl_stub INTERFACE WOWEE_SWITCH_crypto)
    add_library(OpenSSL::SSL ALIAS WOWEE_SWITCH_ssl_stub)
endif()
if(NOT DEFINED OPENSSL_VERSION)
    set(OPENSSL_VERSION "shim (switch/compat)")
endif()
set(OPENSSL_FOUND TRUE)
