from collections import defaultdict

from app.store import Store


class Loader:
    def __init__(self, store):
        self.store = store

    def load(self, path):
        return defaultdict(dict)


def load_default(path):
    return Loader(Store()).load(path)
