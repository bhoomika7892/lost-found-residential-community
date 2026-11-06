"""Generate sentence embeddings for items and store them in item.embedding.

Usage:
    python scripts/generate_embeddings.py                 # every item
    python scripts/generate_embeddings.py --missing-only  # only items whose
                                                          # embedding is NULL

--missing-only is the mode to use after editing items: the database trigger
trg_item_text_changed clears an item's stale embedding, and this refills it.

The connection string is read from the DATABASE_URL environment variable so
that no password is stored in the repository, e.g.

    PowerShell:  $env:DATABASE_URL = "postgresql://lostfound_user:<password>@localhost:55433/lost_found_db"
    bash:        export DATABASE_URL="postgresql://lostfound_user:<password>@localhost:55433/lost_found_db"
"""

import argparse
import os
import sys

import psycopg
from pgvector.psycopg import register_vector
from sentence_transformers import SentenceTransformer

MODEL_NAME = "all-MiniLM-L6-v2"  # produces 384-dimensional vectors


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
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--missing-only",
        action="store_true",
        help="only embed items whose embedding is NULL",
    )
    args = parser.parse_args()

    database_url = os.environ.get("DATABASE_URL")
    if not database_url:
        print("DATABASE_URL environment variable is missing", file=sys.stderr)
        sys.exit(1)

    query = """
        SELECT item_id, item_name, color, brand, description
        FROM item
        {where}
        ORDER BY item_id;
    """.format(where="WHERE embedding IS NULL" if args.missing_only else "")

    with psycopg.connect(database_url) as conn:
        register_vector(conn)

        with conn.cursor() as cur:
            cur.execute(query)
            rows = cur.fetchall()

            if not rows:
                print("No items need embeddings.")
                return

            model = SentenceTransformer(MODEL_NAME)

            texts = [build_item_text(row[1:]) for row in rows]
            embeddings = model.encode(texts, normalize_embeddings=True)

            for row, embedding in zip(rows, embeddings):
                cur.execute(
                    """
                    UPDATE item
                    SET embedding = %s
                    WHERE item_id = %s;
                    """,
                    (embedding.tolist(), row[0]),
                )

            conn.commit()
            print(f"Generated and saved embeddings for {len(rows)} items.")


if __name__ == "__main__":
    main()
