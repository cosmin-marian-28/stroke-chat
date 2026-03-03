-- Create chat-media storage bucket for image/video messages
INSERT INTO storage.buckets (id, name, public, file_size_limit)
VALUES ('chat-media', 'chat-media', true, 31457280)
ON CONFLICT (id) DO NOTHING;

-- Allow authenticated users to upload to chat-media
CREATE POLICY "Authenticated users can upload chat media"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (bucket_id = 'chat-media');

-- Allow public read access
CREATE POLICY "Public read access for chat media"
ON storage.objects FOR SELECT
TO public
USING (bucket_id = 'chat-media');

-- Add media_url column to messages
ALTER TABLE messages ADD COLUMN IF NOT EXISTS media_url text;
