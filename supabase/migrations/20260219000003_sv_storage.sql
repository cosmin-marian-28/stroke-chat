-- Create sv storage bucket for sound visual sticker files
INSERT INTO storage.buckets (id, name, public, file_size_limit)
VALUES ('sv', 'sv', true, 5242880)
ON CONFLICT (id) DO NOTHING;

-- Allow authenticated users to upload their own sv files
CREATE POLICY "Users can upload own sv files"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'sv'
  AND (storage.foldername(name))[1] = (select auth.uid()::text)
);

-- Allow authenticated users to list/read their own sv files
CREATE POLICY "Users can read own sv files"
ON storage.objects FOR SELECT
TO authenticated
USING (
  bucket_id = 'sv'
  AND (storage.foldername(name))[1] = (select auth.uid()::text)
);

-- Allow public read for sharing stickers
CREATE POLICY "Public read access for sv files"
ON storage.objects FOR SELECT
TO public
USING (bucket_id = 'sv');

-- Allow users to delete their own sv files
CREATE POLICY "Users can delete own sv files"
ON storage.objects FOR DELETE
TO authenticated
USING (
  bucket_id = 'sv'
  AND (storage.foldername(name))[1] = (select auth.uid()::text)
);
