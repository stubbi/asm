-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Diagnostic candidate. Both parameters remain literal text.
-- Keep the empty-search page path; select latest releases once for searches.
WITH latest_search AS NOT MATERIALIZED (
    SELECT DISTINCT ON (p.full_name)
           p.full_name AS name, r.version AS latest, r.summary, r.license,
           p.namespace, r.id AS release_id
    FROM asm.packages p
    JOIN asm.releases r ON r.package_id = p.id
    JOIN asm.publication_events e ON e.release_id = r.id
    WHERE $1 <> '' AND NOT e.yanked
      AND ($2 = '' OR p.full_name > $2 COLLATE "C")
    ORDER BY p.full_name, r.major DESC, r.minor DESC, r.patch DESC
), matched AS MATERIALIZED (
    SELECT * FROM (
        (SELECT p.full_name AS name, r.version AS latest, r.summary, r.license,
                p.namespace, r.id AS release_id
         FROM asm.packages p
         JOIN LATERAL (
             SELECT r.id, r.version, r.summary, r.license
             FROM asm.releases r
             JOIN asm.publication_events e ON e.release_id = r.id
             WHERE r.package_id = p.id AND NOT e.yanked
             ORDER BY r.major DESC, r.minor DESC, r.patch DESC LIMIT 1
         ) r ON true
         WHERE $1 = '' AND ($2 = '' OR p.full_name > $2 COLLATE "C")
         ORDER BY p.full_name LIMIT 21)
        UNION ALL
        (SELECT name, latest, summary, license, namespace, release_id
         FROM latest_search
         WHERE strpos(lower(name), lower($1)) > 0
            OR strpos(lower(summary), lower($1)) > 0
         ORDER BY name LIMIT 21)
    ) candidates
    ORDER BY name LIMIT 21
), page AS MATERIALIZED (
    SELECT m.name, m.latest, m.summary, m.license,
           a.github_id AS owner_github_id,
           ARRAY(SELECT DISTINCT target FROM asm.artifacts
                 WHERE release_id = m.release_id ORDER BY target) AS targets
    FROM (SELECT * FROM matched ORDER BY name LIMIT 20) m
    JOIN asm.namespaces n ON n.name = m.namespace
    JOIN asm.accounts a ON a.id = n.owner_id
)
SELECT json_build_object(
    'schema', 0,
    'experimental', true,
    'packages', coalesce((SELECT json_agg(page ORDER BY name) FROM page), '[]'::json),
    'next_after', CASE WHEN (SELECT count(*) FROM matched) > 20
                       THEN (SELECT name FROM page ORDER BY name DESC LIMIT 1)
                       ELSE NULL END,
    'order', 'package-name-ascii'
)::text
