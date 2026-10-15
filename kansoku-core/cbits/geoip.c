/* Country-only binding to mori://maxmind/libmaxminddb. No database parser here. */
#include <arpa/inet.h>
#include <maxminddb.h>
#include <stdlib.h>
#include <string.h>

void *ks_geo_open(const char *path) {
  MMDB_s *db = calloc(1, sizeof(*db));
  if (!db) return NULL;
  if (MMDB_open(path, MMDB_MODE_MMAP, db) != MMDB_SUCCESS) {
    free(db);
    return NULL;
  }
  const char *kind = db->metadata.database_type;
  if (!kind || (strcmp(kind, "GeoIP2-Country") &&
                strcmp(kind, "GeoLite2-Country") &&
                strcmp(kind, "GeoIP2-City") &&
                strcmp(kind, "GeoLite2-City"))) {
    MMDB_close(db);
    free(db);
    return NULL;
  }
  return db;
}

void ks_geo_close(void *handle) {
  if (handle) { MMDB_close(handle); free(handle); }
}

int ks_geo_country(void *handle, const char *address, char *country) {
  struct sockaddr_storage storage;
  memset(&storage, 0, sizeof(storage));
  struct sockaddr_in *v4 = (struct sockaddr_in *)&storage;
  struct sockaddr_in6 *v6 = (struct sockaddr_in6 *)&storage;
  if (inet_pton(AF_INET, address, &v4->sin_addr) == 1) {
    v4->sin_family = AF_INET;
  } else if (inet_pton(AF_INET6, address, &v6->sin6_addr) == 1) {
    v6->sin6_family = AF_INET6;
  } else return 0;
  int error = MMDB_SUCCESS;
  MMDB_lookup_result_s found = MMDB_lookup_sockaddr(handle, (struct sockaddr *)&storage, &error);
  if (error != MMDB_SUCCESS || !found.found_entry) return 0;
  MMDB_entry_data_s value;
  if (MMDB_get_value(&found.entry, &value, "country", "iso_code", NULL) != MMDB_SUCCESS ||
      !value.has_data || value.type != MMDB_DATA_TYPE_UTF8_STRING || value.data_size != 2)
    return 0;
  if (value.utf8_string[0] < 'A' || value.utf8_string[0] > 'Z' ||
      value.utf8_string[1] < 'A' || value.utf8_string[1] > 'Z') return 0;
  memcpy(country, value.utf8_string, 2);
  return 1;
}
