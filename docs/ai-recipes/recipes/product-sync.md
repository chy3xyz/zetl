# Recipe: 商品目录同步 (camelCase → snake_case)

## 目标

源端商品表用 camelCase 列名 (`productName`, `unitPrice`), 目标端标准命名是 snake_case. 用 Phase 6b 的 `naming_rule: "camel_to_snake"` 自动转换, 无需手工写 `field_mappings_json`.

## 源表 `mall_001.products` 结构 (驼峰)

```sql
CREATE TABLE products (
  id           BIGINT        NOT NULL PRIMARY KEY,
  productName  VARCHAR(255)  NOT NULL,
  unitPrice    DECIMAL(10,2) NOT NULL,
  categoryId   INT           NOT NULL,
  createTime   DATETIME      NOT NULL
);
```

## 目标表 `central.product` 期望 (下划线)

```sql
CREATE TABLE product (
  id            BIGINT        NOT NULL PRIMARY KEY,
  mall_id       VARCHAR(32)   NOT NULL,
  product_name  VARCHAR(255)  NOT NULL,
  unit_price    DECIMAL(10,2) NOT NULL,
  category_id   INT           NOT NULL,
  create_time   DATETIME      NOT NULL,
  sync_time     DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE KEY uk_mall_product(mall_id, id)
);
```

## 完整 `config_json`

```json
{
  "name": "product-sync-from-mall-001",
  "sync_mode": "both",
  "source": {
    "host": "polar-001.local", "port": 3306,
    "user": "etl", "password": "<encrypted>",
    "db": "mall_001", "table": "products",
    "mall_id": "mall-001"
  },
  "target": {
    "host": "central.local", "port": 3306,
    "user": "etl", "password": "<encrypted>",
    "db": "central", "table": "product"
  },
  "transform": {
    "naming_rule": "camel_to_snake"
  },
  "sink": {
    "on_conflict": "replace"
  }
}
```

## 字段解读

- `naming_rule: "camel_to_snake"`: `productName` 自动变成 `product_name`, 无需写 `field_mappings_json`.
- 想加更复杂规则 (比如 `naming_rule: "camel_to_snake"` 后再加 `add_prefix("dt_")`) 用 Phase 6c 的 `naming_rules` 数组, 详见 [reference/transform-naming.md](../reference/transform-naming.md).

## 验证

1. 源插一行 `productName='iPhone 15', unitPrice=5999.00`.
2. 目标查: `SELECT product_name, unit_price FROM product WHERE id = ?;` → `iPhone 15 | 5999.00`.
