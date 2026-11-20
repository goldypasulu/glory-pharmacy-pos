-- name: SyncWatermark :one
-- Batas atas pull sync (xid8 selalu di-cast ke text, lihat CLAUDE.md "Aturan sync").
SELECT sync_watermark()::text AS watermark;
