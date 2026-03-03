-- Migrate placed_stickers to anchor stickers to messages instead of scroll offsets
-- Drop old columns and add message-relative positioning

alter table public.placed_stickers
  add column if not exists message_id text,
  add column if not exists offset_x double precision not null default 0.5,
  add column if not exists offset_y double precision not null default 0;

-- Migrate existing data: keep them but they'll be orphaned (no message_id)
-- New stickers will always have message_id set

-- Drop old x/y columns
alter table public.placed_stickers
  drop column if exists x,
  drop column if exists y;
