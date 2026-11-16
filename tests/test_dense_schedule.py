from model.dense_schedule import trace


def test_hand_identity():
    t = trace([[1, 2], [3, 4]], [[1, 0], [0, 1]])
    assert [x["c"] for x in t] == [
        [[1, 0], [0, 0]],
        [[1, 0], [3, 0]],
        [[1, 2], [3, 0]],
        [[1, 2], [3, 4]],
    ]
    assert [(p["r"], p["c"], p["k"]) for p in t[1]["products"]] == [
        (0, 0, 1),
        (0, 1, 0),
        (1, 0, 0),
    ]
