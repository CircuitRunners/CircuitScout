import { useConvexAuth } from "convex/react";
import { Navigate, Outlet } from "react-router";

export function AuthLayout() {
  const { isLoading, isAuthenticated } = useConvexAuth();

  if (isLoading) return null;
  if (isAuthenticated) return <Navigate to="/" replace />;

  return (
    <div className="flex min-h-svh items-center justify-center p-6">
      <div className="w-full max-w-sm">
        <Outlet />
      </div>
    </div>
  );
}
