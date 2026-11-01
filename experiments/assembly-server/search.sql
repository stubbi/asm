-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Both arguments are text parameters. '%' and quotes have no SQL meaning here.
-- This experimental endpoint has a fixed page size and an explicit next name.
WITH matched AS MATERIALIZED (
    SELECT p.full_name AS name, r.version AS latest, r.summary, r.license,
           a.github_id AS owner_github_id,
           ARRAY(SELECT DISTINCT target FROM asm.artifacts
                 WHERE release_id = r.id ORDER BY target) AS targets
    FROM asm.packages p
    JOIN asm.namespaces n ON n.name = p.namespace
    JOIN asm.accounts a ON a.id = n.owner_id
    JOIN LATERAL (
        SELECT r.* FROM asm.releases r
        JOIN asm.publication_events e ON e.release_id = r.id
        WHERE r.package_id = p.id AND NOT e.yanked
        ORDER BY r.major DESC, r.minor DESC, r.patch DESC LIMIT 1
    ) r ON true
    WHERE ($1 = '' OR strpos(lower(p.full_name), lower($1)) > 0
                   OR strpos(lower(r.summary), lower($1)) > 0)
      AND ($2 = '' OR p.full_name > $2 COLLATE "C")
    ORDER BY p.full_name LIMIT 21
), page AS (SELECT * FROM matched ORDER BY name LIMIT 20)
SELECT json_build_object(
    'schema', 0,
    'experimental', true,
    'packages', coalesce((SELECT json_agg(page ORDER BY name) FROM page), '[]'::json),
    'next_after', CASE WHEN (SELECT count(*) FROM matched) > 20
                       THEN (SELECT name FROM page ORDER BY name DESC LIMIT 1)
                       ELSE NULL END,
    'order', 'package-name-ascii'
)::text
