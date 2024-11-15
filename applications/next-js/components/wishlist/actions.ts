'use server';

import { TAGS } from 'lib/constants';
import { addToWishlist, createWishlist, getWishlist, removeFromWishlist } from 'lib/dynamo';
import { revalidateTag } from 'next/cache';
import { cookies } from 'next/headers';
import {CartProduct, Product, Wishlist} from '../../lib/dynamo/types';

export async function addWishlistItem(prevState: any, wishlistItem: CartProduct) {
  let wishlistId = cookies().get('wishlistId')?.value;
  let wishlist;

  if (wishlistId) {
    wishlist = await getWishlist(wishlistId);
  }

  if (!wishlistId || !wishlist) {
    wishlist = await createWishlist();
    wishlistId = wishlist.id;
    cookies().set('wishlistId', wishlistId);
  }

  if (!wishlistItem) {
    return 'Missing product variant ID';
  }

  try {
    await addToWishlist(wishlistId, wishlistItem);
    revalidateTag(TAGS.wishlist);
  } catch (e) {
    return 'Error adding item to wishlist';
  }
}

export async function removeWishlistItem(prevState: any, productId: string) {
  const wishlistId = cookies().get('wishlistId')?.value;

  if (!wishlistId) {
    return 'Missing wishlist ID';
  }

  try {
    await removeFromWishlist(wishlistId, productId);
    revalidateTag(TAGS.wishlist);
  } catch (e) {
    return 'Error removing item from wishlist';
  }
}
