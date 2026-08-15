-- Both extensions must exist BEFORE the dump is loaded:
--   * pg_trgm    : GIN indexes metapackages_effname_trgm / maintainers_maintainer_trgm
--   * libversion : function repology.version_set_changed() -> version_compare2()
--
-- The dump does not create them (its CREATE EXTENSION clauses are commented
-- out, only a superuser may install them) and it restores with an empty
-- search_path, referencing extension objects as public.* — hence the schema.

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS libversion WITH SCHEMA public;
