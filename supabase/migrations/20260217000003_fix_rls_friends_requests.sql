-- Fix friends insert: allow inserting reciprocal row when a pending request exists
-- (i.e. user A accepts request from user B → inserts row for B too)
DROP POLICY "Users can insert own friends" ON public.friends;

CREATE POLICY "Users can insert friends on accept"
  ON public.friends FOR INSERT TO authenticated
  WITH CHECK (
    -- Can always insert your own row
    (select auth.uid()) = user_id
    OR
    -- Can insert the reciprocal row if there's a pending request between the two
    EXISTS (
      SELECT 1 FROM public.friend_requests
      WHERE status = 'pending'
      AND (
        (from_uid = user_id AND to_uid = friend_id)
        OR (from_uid = friend_id AND to_uid = user_id)
      )
    )
  );

-- Fix friend_requests select: also allow reading requests you sent
DROP POLICY "Users can read requests sent to them" ON public.friend_requests;

CREATE POLICY "Users can read own requests"
  ON public.friend_requests FOR SELECT TO authenticated
  USING (
    (select auth.uid()) = to_uid
    OR (select auth.uid()) = from_uid
  );

-- Fix friend_requests delete: also allow cancelling requests you sent
DROP POLICY "Users can delete requests sent to them" ON public.friend_requests;

CREATE POLICY "Users can delete own requests"
  ON public.friend_requests FOR DELETE TO authenticated
  USING (
    (select auth.uid()) = to_uid
    OR (select auth.uid()) = from_uid
  );
