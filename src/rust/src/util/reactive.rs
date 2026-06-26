use arc_swap::ArcSwap;
use std::sync::Arc;

pub struct Signal<T>(Arc<ArcSwap<T>>);

impl<T> Clone for Signal<T> {
    fn clone(&self) -> Self {
        Self(Arc::clone(&self.0))
    }
}

impl<T: std::fmt::Debug + Send + Sync + 'static> std::fmt::Debug for Signal<T> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Signal")
            .field("value", &**self.0.load())
            .finish()
    }
}

impl<T: Send + Sync + 'static> Signal<T> {
    pub fn new(value: T) -> Self {
        Self(Arc::new(ArcSwap::new(Arc::new(value))))
    }

    pub fn get(&self) -> T
    where
        T: Clone,
    {
        (**self.0.load()).clone()
    }

    pub fn with<R>(&self, f: impl FnOnce(&T) -> R) -> R {
        f(&**self.0.load())
    }

    pub fn set(&self, value: T) {
        self.0.store(Arc::new(value));
    }

    pub fn update(&self, f: impl FnOnce(&mut T))
    where
        T: Clone,
    {
        let current = self.0.load();
        let mut val = (**current).clone();
        f(&mut val);
        self.0.store(Arc::new(val));
    }
}
