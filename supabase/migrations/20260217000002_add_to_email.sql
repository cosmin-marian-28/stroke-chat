-- Add to_email column to friend_requests so sent requests can display the target
ALTER TABLE friend_requests ADD COLUMN IF NOT EXISTS to_email text;
