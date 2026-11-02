import os
import sys

import psycopg
from pgvector.psycopg import register_vector
from sentence_transformers import SentenceTransformer


def build_item_text(row):
    item_name, color, brand, description = row

    parts = [
        f"Item: {item_name}",
        f"Color: {color}" if color else None,
        f"Brand: {brand}" if brand else None,
        f"Description: {description}" if description else None,
    ]

    return ". ".join(part for part in parts if part)


def main():
    if len(sys.argv) != 2:
        print("Usage: generate_item_embedding.py <item_id>", file=sys.stderr)
        sys.exit(1)

    item_id = int(sys.argv[1])
    database_url = os.environ.get("DATABASE_URL")

    if not database_url:
        print("DATABASE_URL environment variable is missing", file=sys.stderr)
        sys.exit(1)

    model = SentenceTransformer("all-MiniLM-L6-v2")

    with psycopg.connect(database_url) as conn:
        register_vector(conn)

        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT item_name, color, brand, description
                FROM item
                WHERE item_id = %s;
                """,
                (item_id,),
            )
            row = cur.fetchone()

            if row is None:
                raise ValueError(f"Item {item_id} not found")

            text = build_item_text(row)
            embedding = model.encode(text, normalize_embeddings=True)

            cur.execute(
                """
                UPDATE item
                SET embedding = %s
                WHERE item_id = %s;
                """,
                (embedding.tolist(), item_id),
            )

        conn.commit()

    print(f"Generated embedding for item {item_id}")


if __name__ == "__main__":
    main()