/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Shared fixed data for native assembly ports. No generated application code.
 * Request: start_ns:u64 at0, route:u32 at8, clock_valid:u32 at12 (16 bytes).
 * Six rows of thirteen u64: three status counters, eight cumulative buckets,
 * sum_ns, count. One final u64 counts unsuccessful response queue attempts.
 * The mutex protects all632 bytes and health; mutex storage is64/alignment16.
 */
.equ METRICS_BYTES, 632
.equ METRICS_ROW, 104
.equ METRICS_SUM, 88
.equ METRICS_COUNT, 96
.equ METRICS_FAILURES, 624
.equ METRICS_REPLY, 16384
.section .rodata
m_sync_error: .asciz "asm-hub: request metrics synchronization failed.\n"
m_sync_error_end:
.equ M_SYNC_ERROR_LENGTH, m_sync_error_end - m_sync_error - 1
m_literal_format: .asciz "%s"
m_requests_header:
.asciz "# HELP asm_http_requests_total Requests whose responses were accepted for queueing; excludes prior header receipt and later client transfer.\n# TYPE asm_http_requests_total counter\n"
m_duration_header:
.asciz "# HELP asm_http_request_duration_seconds Handler entry to accepted response queueing in seconds; excludes prior header receipt and later client transfer.\n# TYPE asm_http_request_duration_seconds histogram\n"
m_failures_header:
.asciz "# HELP asm_http_connection_failures_total Handled requests whose responses could not be queued; excludes post-queue transfer failures.\n# TYPE asm_http_connection_failures_total counter\n"
m_requests_format: .asciz "asm_http_requests_total{route=\"%s\",status_class=\"%s\"} %llu\n"
m_bucket_format: .asciz "asm_http_request_duration_seconds_bucket{route=\"%s\",le=\"%s\"} %llu\n"
m_sum_format: .asciz "asm_http_request_duration_seconds_sum{route=\"%s\"} %llu.%09llu\n"
m_count_format: .asciz "asm_http_request_duration_seconds_count{route=\"%s\"} %llu\n"
m_failures_format: .asciz "asm_http_connection_failures_total %llu\n"
m_live: .asciz "live"
m_ready: .asciz "ready"
m_about: .asciz "about"
m_index: .asciz "index"
m_metrics: .asciz "metrics"
m_other: .asciz "other"
m_2xx: .asciz "2xx"
m_4xx: .asciz "4xx"
m_5xx: .asciz "5xx"
m_b0: .asciz "0.005"
m_b1: .asciz "0.01"
m_b2: .asciz "0.05"
m_b3: .asciz "0.1"
m_b4: .asciz "0.5"
m_b5: .asciz "1"
m_b6: .asciz "2"
m_b7: .asciz "+Inf"
m_path_live: .asciz "/health/live"
m_path_ready: .asciz "/health/ready"
m_path_about: .asciz "/api/v2/status"
m_path_index0: .asciz "/registry/v1/index.tsv"
m_path_index1: .asciz "/registry/v1/index-macos.tsv"
m_path_index2: .asciz "/registry/v1/index-all.tsv"
m_path_index3: .asciz "/registry/v1/index.json"
m_path_metrics: .asciz "/metrics"
.balign 8
m_bucket_ns: .quad 5000000,10000000,50000000,100000000,500000000,1000000000,2000000000,-1
.section .data.rel.ro,"aw"
.balign 8
m_routes: .quad m_live,m_ready,m_about,m_index,m_metrics,m_other
m_classes: .quad m_2xx,m_4xx,m_5xx
m_boundaries: .quad m_b0,m_b1,m_b2,m_b3,m_b4,m_b5,m_b6,m_b7
m_paths: .quad m_path_live,0,m_path_ready,1,m_path_about,2,m_path_index0,3,m_path_index1,3,m_path_index2,3,m_path_index3,3,m_path_metrics,4,0,5
.section .bss
.balign 16
m_mutex: .zero 64
.balign 8
m_table: .zero METRICS_BYTES
m_health: .zero 4
