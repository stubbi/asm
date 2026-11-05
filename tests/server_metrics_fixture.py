"""Controlled metadata for qualification-validator tests; no native result.

SPDX-License-Identifier: AGPL-3.0-or-later
"""


def metrics():
    return {"schema": 1, "timing": "handler-entry-to-accepted-queue", "samples": 79,
            "max_response_bytes": 16384,
            "http_tests": ["RuntimeTests.test_metrics_" + name for name in (
                "aborts_preserve_queue_semantics", "concurrent_scrapes_preserve_snapshots",
                "database_delay_and_failed_request_timing", "errors_and_exactly_once_queue_accounting",
                "fixed_exposition_and_route_labels", "queue_failures_preserve_ownership")],
            "unit": {"schema": 1, "status": "pass", "scope": "assembly-metrics-unit", "checks": [
                "zero_exposition", "route_classification", "bucket_boundaries", "decimal_sum_and_capacity",
                "queue_failure", "parallel_snapshot", "clock_failure_begin", "clock_failure_finish",
                "clock_invalid_timespec", "clock_conversion_overflow", "clock_backwards", "overflow_count",
                "overflow_request_counter", "overflow_bucket", "overflow_sum", "overflow_queue_failure",
                "mutex_init_failure", "mutex_lock_failure", "mutex_unlock_failure"]},
            "test_tools": {"test-metrics": {"sha256": "2" * 64, "bytes": 16384},
                           "metrics-faults.so": {"sha256": "3" * 64, "bytes": 12288}}}


CASES = {'baseline': ['RuntimeTests.test_canonical_exports_preserve_exact_current_bytes_and_media_types',
              'RuntimeTests.test_cli_and_bind_configuration_fail_closed',
              'RuntimeTests.test_concurrent_exports_keep_independent_response_ownership',
              'RuntimeTests.test_encrypted_client_key_never_prompts_on_an_open_terminal',
              'RuntimeTests.test_export_body_byte_limits_preserve_boundary_bytes',
              'RuntimeTests.test_export_database_work_obeys_the_request_deadline',
              'RuntimeTests.test_exports_reject_missing_null_duplicate_and_unready_results',
              'RuntimeTests.test_health_and_exact_source_identity',
              'RuntimeTests.test_metrics_aborts_preserve_queue_semantics',
              'RuntimeTests.test_metrics_concurrent_scrapes_preserve_snapshots',
              'RuntimeTests.test_metrics_database_delay_and_failed_request_timing',
              'RuntimeTests.test_metrics_errors_and_exactly_once_queue_accounting',
              'RuntimeTests.test_metrics_fixed_exposition_and_route_labels',
              'RuntimeTests.test_metrics_queue_failures_preserve_ownership',
              'RuntimeTests.test_new_connections_load_replaced_certificate_files',
              'RuntimeTests.test_private_configuration_file_is_required',
              'RuntimeTests.test_reader_rejects_migrator_operator_and_wrong_tls_identities',
              'RuntimeTests.test_readiness_checks_actual_permissions_after_start',
              'RuntimeTests.test_stalled_database_handshake_has_a_deadline',
              'RuntimeTests.test_tls_policy_rejects_ambient_options_and_ambiguous_connections',
              'RuntimeTests.test_unimplemented_write_routes_do_not_claim_success',
              'RuntimeTests.test_z_sigterm_closes_the_listener_within_three_seconds'],
 'capacity': ['CapacityTests.test_aborted_database_handshakes_release_admission',
              'CapacityTests.test_eight_handshakes_refuse_ninth_and_recover_in_the_same_process',
              'CapacityTests.test_guard_failures_release_admission_before_recovery',
              'CapacityTests.test_http_disconnects_release_admission_by_the_database_deadline',
              'CapacityTests.test_http_response_abort_preserves_database_capacity',
              'CapacityTests.test_invalid_results_release_admission_before_recovery',
              'CapacityTests.test_null_connection_creation_releases_admission',
              'CapacityTests.test_replacement_acquisitions_overlap_individual_releases',
              'CapacityTests.test_sixteen_contending_requests_never_hold_more_than_eight_connections',
              'CapacityTests.test_statement_timeouts_release_admission_before_recovery',
              'CapacityTests.test_successful_reads_release_admission_repeatedly',
              'CapacityTests.test_tls_failures_release_admission_before_recovery'],
 'envelope': ['EnvelopeTests.test_eight_slow_maximum_exports_preserve_bytes_and_recover',
              'EnvelopeTests.test_incomplete_headers_release_connections_after_inactivity',
              'EnvelopeTests.test_sigterm_bounds_exit_during_observed_inflight_work']}
