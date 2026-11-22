#!/usr/bin/env python3
"""Regenerates products.json and skus.json (deterministic). Only needed to change the demo data."""
import json, random
random.seed(7)
P = [  # title, brand, category, description, base price, variants
 ("Trailblazer Waterproof Hiking Jacket","Nordvik","Clothing > Outdoor","Lightweight three-layer waterproof shell with taped seams and a packable hood.",89,("colour",["black","olive","navy"]),("size",["S","M","L","XL"])),
 ("Summit Merino Base Layer","Nordvik","Clothing > Outdoor","Breathable merino wool thermal top for cold-weather hiking and skiing.",45,("colour",["grey","navy"]),("size",["S","M","L"])),
 ("Ridge Trail Running Shoes","Stride","Footwear > Running","Cushioned trail running shoes with aggressive grip for wet and muddy paths.",74,("colour",["red","black"]),("size",["40","42","44"])),
 ("Cloudstep Everyday Sneakers","Stride","Footwear > Casual","Comfortable canvas sneakers for everyday wear with a memory-foam insole.",39,("colour",["white","black","grey"]),("size",["38","40","42"])),
 ("Alpine 40L Backpack","Nordvik","Bags > Backpacks","Durable 40 litre hiking backpack with rain cover and ventilated back panel.",65,("colour",["green","black"]),None),
 ("Urban Commuter Laptop Backpack","Kestrel","Bags > Backpacks","Water-resistant 15 inch laptop backpack with USB charging port and anti-theft pocket.",42,("colour",["black","grey","blue"]),None),
 ("Aero Insulated Water Bottle 750ml","Hydra","Sports > Hydration","Double-wall stainless steel bottle that keeps drinks cold for 24 hours or hot for 12.",19,("colour",["steel","black","teal"]),None),
 ("Pulse Wireless Earbuds","Kestrel","Electronics > Audio","Bluetooth 5.3 earbuds with active noise cancelling and 30 hour battery case.",59,("colour",["white","black"]),None),
 ("Beacon Smart Fitness Tracker","Kestrel","Electronics > Wearables","Heart-rate and sleep tracking band with 14 day battery and GPS.",49,("colour",["black","pink","blue"]),None),
 ("Lumen LED Camping Lantern","Nordvik","Outdoor > Camping","Rechargeable collapsible LED lantern with warm and cool light modes.",24,("colour",["orange","grey"]),None),
 ("Cascade 2-Person Dome Tent","Nordvik","Outdoor > Camping","Easy-pitch waterproof two person tent with double doors and vestibule.",110,("colour",["green","orange"]),None),
 ("Forge Cast Iron Skillet 26cm","Hearth","Home > Kitchen","Pre-seasoned cast iron frying pan suitable for hob, oven and open fire.",34,("colour",["black"]),None),
 ("Hearth Chef's Knife 20cm","Hearth","Home > Kitchen","Forged high-carbon steel chef's knife with a balanced ergonomic handle.",52,("colour",["black","walnut"]),None),
 ("Brew Pour-Over Coffee Set","Hearth","Home > Kitchen","Glass carafe, reusable steel filter and scoop for pour-over coffee.",29,("colour",["clear"]),None),
 ("Dreamcloud Memory Foam Pillow","Slumber","Home > Bedroom","Contoured memory foam pillow with a cooling gel layer and washable cover.",32,("size",["standard","king"]),None),
 ("Slumber Egyptian Cotton Duvet Set","Slumber","Home > Bedroom","400 thread count Egyptian cotton duvet cover and pillowcases.",69,("colour",["white","sage","charcoal"]),("size",["double","king"])),
 ("Glide Yoga Mat 6mm","Hydra","Sports > Yoga","Non-slip eco-friendly TPE yoga mat with carrying strap.",27,("colour",["purple","teal","grey"]),None),
 ("Iron Core Adjustable Dumbbell Pair","Stride","Sports > Fitness","Adjustable dumbbells from 2 to 20 kg per hand with a quick-lock dial.",120,("colour",["black"]),None),
 ("Sprout Kids Raincoat","Puddle","Clothing > Kids","Bright waterproof raincoat for children with reflective trims and a hood.",28,("colour",["yellow","red","blue"]),("size",["3-4y","5-6y","7-8y"])),
 ("Puddle Kids Wellington Boots","Puddle","Footwear > Kids","Soft rubber wellies with easy-pull handles and a non-slip sole.",22,("colour",["yellow","green"]),("size",["28","30","32"])),
]
MERCH = ["m-100","m-200","m-300","m-400"]
products, skus, n = [], [], 0
for i,(title,brand,cat,desc,base,v1,v2) in enumerate(P, start=1):
    poid = f"P{i:04d}"
    products.append({"product_oid":poid,"title":title,"brand":brand,"category":cat,"description":desc})
    combos=[{}]
    for v in (v1,v2):
        if v: combos=[{**c,v[0]:val} for c in combos for val in v[1]]
    for merch in random.sample(MERCH, random.choice([1,2])):
        for c in combos:
            n+=1
            stock=random.choice([0,0,3,8,15,40,120])
            skus.append({"sku_oid":f"S{n:05d}","product_oid":poid,"merchant_id":merch,
              **c,"price":round(base*random.uniform(0.9,1.15),2),"currency":"GBP",
              "stock":stock,"in_stock":stock>0})
json.dump(products,open("products.json","w"),indent=1)
json.dump(skus,open("skus.json","w"),indent=1)
print(len(products),"products",len(skus),"skus")
