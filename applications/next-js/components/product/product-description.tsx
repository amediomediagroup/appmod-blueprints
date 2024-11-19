import { AddToCart } from "components/cart/add-to-cart";
import Price from "components/price";
import Prose from "components/prose";
import { Product } from "lib/dynamo/types";
import { Suspense } from "react";
import { VariantSelector } from "./variant-selector";
import {AddToWishlist} from "../wishlist/add-to-wishlist";

export function ProductDescription({ product }: { product: Product }) {
  return (
    <>
      <div className="mb-6 flex flex-col border-b pb-6 dark:border-neutral-700">
        <h1 className="mb-2 text-5xl font-medium">{product.name}</h1>
        <div className="mr-auto w-auto rounded-full bg-blue-600 p-2 text-sm text-white">
          <Price amount={product.price} currencyCode={"USD"} />
        </div>
      </div>
      <Suspense fallback={null}>
        <VariantSelector
          options={product.options}
          variants={product.variants}
        />
      </Suspense>

      {product.description ? (
        <Prose
          className="mb-6 text-sm leading-tight dark:text-white/[60%]"
          html={product.description}
        />
      ) : null}

      <Suspense fallback={null}>
        <AddToWishlist product={product} variants={product.variants} />
        <div className="flex h-5"></div>
        <AddToCart product={product} variants={product.variants} />
      </Suspense>
    </>
  );
}
