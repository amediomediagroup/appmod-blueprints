export type Menu = {
  title: string;
  path: string;
};

export type Page = {
  id: string;
  title: string;
  handle: string;
  body: string;
  bodySummary: string;
  createdAt: string;
  updatedAt: string;
};

export type Category = {
  path: string;
  categoryId: string;
  title: string;
  description: string;
};

export type Image = {
  url: string;
  altText: string;
  width: number;
  height: number;
};

export type CartProduct = {
  product: Product;
  quantity: number;
  selected_variant: ProductVariants;
  selected_option: ProductOptions;
}

export type ProductOptions = {
  id: string;
  name: string;
  values: string[];
};

export type ProductVariants = {
  id: string;
  title: string;
  price: string;
};

export type Product = {
  id: string;
  name: string;
  description: string;
  inventory: number;
  options: ProductOptions[];
  variants: ProductVariants[];
  price: string;
  images: Image[];
};

export type CartItem = {
  id: string;
  quantity: number;
  cost: string;
  merchandise: {
    id: string;
    title: string;
    selectedOptions: {
      name: string;
      value: string;
    }[];
    product: Product;
  };
};

export type Cart = {
  id: string;
  products: CartItem[];
  totalQuantity: number;
  cost: string;
  checkoutUrl: string;
};
