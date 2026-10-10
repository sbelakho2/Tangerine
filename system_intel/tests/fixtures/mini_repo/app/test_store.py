from app.store import Store


def test_put_returns_value():
    return Store().put("k", "v") == "v"
